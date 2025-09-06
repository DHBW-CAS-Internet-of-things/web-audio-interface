<template>
  <q-card class="q-pa-md">
    <div class="row items-center q-gutter-sm q-mb-sm">
      <q-btn
        :disable="isRunning"
        color="primary"
        icon="mic"
        :label="$t('audio-component.start')"
        @click="start"
        no-caps
      />
      <q-btn
        :disable="!isRunning"
        color="negative"
        icon="stop"
        :label="$t('audio-component.stop')"
        @click="stop"
        no-caps
      />
    </div>

    <q-banner v-if="isRunning" class="bg-grey-2 q-mb-sm" dense>
      {{ $t('audio-component.recording') }}{{ elapsedLabel }}{{ $t('audio-component.sent')
      }}{{ sent }}
    </q-banner>
    <q-banner v-if="status" class="bg-grey-2 q-mb-sm" dense>{{ status }}</q-banner>
    <q-banner v-if="error" class="bg-red-2 text-negative q-mb-sm" dense>{{ error }}</q-banner>
    <q-banner v-if="lastResult" class="bg-grey-2 q-mb-sm" dense>
      t={{ lastResult.t.toFixed(1) }}s · p_clap={{ lastResult.p_clap.toFixed(3) }} · p_noise={{
        lastResult.p_noise.toFixed(3)
      }}
    </q-banner>
  </q-card>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue';

const isRunning = ref(false);
const status = ref('');
const error = ref('');
const sent = ref(0);
const startTs = ref<number | null>(null);
const elapsed = ref(0);
let tick: number | null = null;
const elapsedLabel = computed(() => {
  const s = Math.floor(elapsed.value / 1000);
  const mm = String(Math.floor(s / 60)).padStart(2, '0');
  const ss = String(s % 60).padStart(2, '0');
  return `${mm}:${ss}`;
});

const TARGET_SR = 16000;
const SAMPLES_PER_BLOCK = TARGET_SR * 1; // 1 s
const WS_URL = import.meta.env.BACKEND_WS_URL || 'ws://clap-recognition-api:8000/ws/stream';

let stream: MediaStream | null = null;
let audioCtx: AudioContext | null = null;
let workletNode: AudioWorkletNode | null = null;
let ws: WebSocket | null = null;

const lastResult = ref<{ t: number; p_clap: number; p_noise: number } | null>(null);

async function start() {
  error.value = '';
  status.value = '';
  lastResult.value = null;
  try {
    // 1) WebSocket öffnen
    ws = new WebSocket(WS_URL);
    ws.binaryType = 'arraybuffer';
    await new Promise<void>((resolve, reject) => {
      const to = setTimeout(() => reject(new Error('WebSocket timeout')), 5000);
      ws!.onopen = () => {
        clearTimeout(to);
        resolve();
      };
      ws!.onerror = () => {
        clearTimeout(to);
        reject(new Error('WebSocket error'));
      };
    });
    ws.onmessage = (ev) => {
      try {
        console.log(ev);
        const msg = JSON.parse(ev.data);
        if (msg.error) {
          error.value = `Server: ${msg.error}`;
          return;
        }
        lastResult.value = { t: msg.t, p_clap: msg.p_clap, p_noise: msg.p_noise };
      } catch (e) {
        console.error(e);
      }
    };

    // 2) Audio starten
    stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1 } });
    audioCtx = new ((window as typeof window & { webkitAudioContext?: typeof AudioContext })
      .AudioContext ||
      (window as typeof window & { webkitAudioContext: typeof AudioContext }).webkitAudioContext)();
    await audioCtx.audioWorklet.addModule(createWorkletUrl());
    const source = audioCtx.createMediaStreamSource(stream);

    workletNode = new AudioWorkletNode(audioCtx, 'pcm16k-worklet', {
      numberOfInputs: 1,
      numberOfOutputs: 0,
      channelCount: 1,
      processorOptions: {
        inputSampleRate: audioCtx.sampleRate,
        targetSampleRate: TARGET_SR,
        blockLen: SAMPLES_PER_BLOCK,
      },
    });
    source.connect(workletNode);

    // 3) PCM-Blocks direkt zum Server schicken
    workletNode.port.onmessage = (ev: MessageEvent) => {
      const { type, payload } = ev.data || {};
      if (type === 'block-int16') {
        const ab: ArrayBuffer = payload; // 32000 Bytes pro 1s Block
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(ab);
          sent.value++;
        }
      }
    };

    isRunning.value = true;
    sent.value = 0;
    startTs.value = performance.now();
    elapsed.value = 0;
    tick = window.setInterval(() => {
      if (startTs.value) elapsed.value = performance.now() - startTs.value;
    }, 150);
  } catch (e: unknown) {
    error.value = (e as Error)?.message || String(e);
    await stop();
  }
}

async function stop() {
  try {
    workletNode?.disconnect();
  } catch (e) {
    console.error(e);
  }
  workletNode = null;
  try {
    stream?.getTracks().forEach((t) => t.stop());
  } catch (e) {
    console.error(e);
  }
  stream = null;
  try {
    await audioCtx?.close();
  } catch (e) {
    console.error(e);
  }
  audioCtx = null;
  try {
    ws?.close();
  } catch (e) {
    console.error(e);
  }
  ws = null;
  isRunning.value = false;
  if (tick) {
    clearInterval(tick);
    tick = null;
  }
  status.value = 'Beendet.';
}

// AudioWorklet unverändert: 16k Resampling + 1s Framing + Int16
function createWorkletUrl(): string {
  const code = `
  class PCM16KProcessor extends AudioWorkletProcessor {
    constructor(options) {
      super()
      const o = options.processorOptions || {}
      this.inSr = o.inputSampleRate || sampleRate
      this.outSr = o.targetSampleRate || 16000
      this.blockLen = o.blockLen || 16000
      this.ratio = this.inSr / this.outSr
      this._residual = new Float32Array(0)
      this._accum = new Float32Array(0)
    }
    _resample(buf) {
      let input
      if (this._residual.length) {
        input = new Float32Array(this._residual.length + buf.length)
        input.set(this._residual, 0)
        input.set(buf, this._residual.length)
      } else input = buf
      const out = new Float32Array(Math.floor(input.length / this.ratio) + 1)
      let pos = 0, outIdx = 0
      while (true) {
        const i = pos | 0
        const frac = pos - i
        const j = i + 1
        if (j >= input.length) break
        const s0 = input[i], s1 = input[j]
        out[outIdx++] = s0 + (s1 - s0) * frac
        pos += this.ratio
      }
      const restStart = pos | 0
      this._residual = restStart < input.length ? input.slice(restStart) : new Float32Array(0)
      return out.subarray(0, outIdx)
    }
    process(inputs) {
      const ch0 = inputs[0]?.[0]
      if (!ch0 || ch0.length === 0) return true
      const res = this._resample(ch0)
      if (res.length) {
        const acc = new Float32Array(this._accum.length + res.length)
        acc.set(this._accum, 0); acc.set(res, this._accum.length)
        this._accum = acc
        while (this._accum.length >= this.blockLen) {
          const block = this._accum.subarray(0, this.blockLen)
          const rest = this._accum.subarray(this.blockLen)
          const i16 = new Int16Array(block.length)
          for (let i=0;i<block.length;i++){
            let s=block[i]; if(s>1)s=1; else if(s<-1)s=-1
            i16[i]= s<0 ? s*0x8000 : s*0x7FFF
          }
          this.port.postMessage({ type:'block-int16', payload: i16.buffer }, [i16.buffer])
          this._accum = rest
        }
      }
      return true
    }
  }
  registerProcessor('pcm16k-worklet', PCM16KProcessor)
  `;
  const blob = new Blob([code], { type: 'application/javascript' });
  return URL.createObjectURL(blob);
}
</script>
