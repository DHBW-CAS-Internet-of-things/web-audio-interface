<template>
  <q-card class="q-pa-md">
    <div class="row items-center q-gutter-sm q-mb-sm">
      <q-btn :disable="isRunning" color="primary" icon="mic" :label="$t('audio-component.start')" @click="start"
             no-caps/>
      <q-btn :disable="!isRunning" color="negative" icon="stop" :label="$t('audio-component.stop')" @click="stop"
             no-caps/>
    </div>

    <q-banner v-if="isRunning" class="bg-grey-2 q-mb-sm" dense>
      {{ $t('audio-component.recording') }}{{ elapsedLabel }}{{ $t('audio-component.sent') }}{{
        sent
      }}{{ $t('audio-component.queue') }}{{ queue.length }}
    </q-banner>
    <q-banner v-if="status" class="bg-grey-2 q-mb-sm" dense>{{ status }}</q-banner>
    <q-banner v-if="error" class="bg-red-2 text-negative q-mb-sm" dense>{{ error }}</q-banner>
  </q-card>
</template>

<script setup lang="ts">
import {computed, ref} from 'vue'
import {useI18n} from "vue-i18n";

/** UI */
const isRunning = ref(false)
const status = ref('')
const error = ref('')
const sent = ref(0)
const startTs = ref<number | null>(null)
const elapsed = ref(0)
let tick: number | null = null
const elapsedLabel = computed(() => {
  const s = Math.floor(elapsed.value / 1000)
  const mm = String(Math.floor(s / 60)).padStart(2, '0')
  const ss = String(s % 60).padStart(2, '0')
  return `${mm}:${ss}`
})

/** Config */
const TARGET_SR = 16000
const CHANNELS = 1
const SAMPLES_PER_BLOCK = TARGET_SR * 1 // 1 s
const BYTES_PER_SAMPLE = 2
const UPLOAD_URL = 'https://localhost:8000/predict/frequency'

/** Audio handles */
let stream: MediaStream | null = null
let audioCtx: AudioContext | null = null
let workletNode: AudioWorkletNode | null = null

/** Upload queue */
type Item = { seq: number; wav: Blob; filename: string; createdAt: number }
const queue = ref<Item[]>([])
let seq = 0
let inFlight = 0
const CONCURRENCY = 2
const MAX_RETRY = 3

async function start() {
  error.value = '';
  status.value = ''
  try {
    stream = await navigator.mediaDevices.getUserMedia({audio: {channelCount: 1}})
    audioCtx = new (window.AudioContext || (window as typeof window & {
      webkitAudioContext: typeof AudioContext
    }).webkitAudioContext)()
    await audioCtx.audioWorklet.addModule(createWorkletUrl())
    const source = audioCtx.createMediaStreamSource(stream)

    workletNode = new AudioWorkletNode(audioCtx, 'pcm16k-worklet', {
      numberOfInputs: 1, numberOfOutputs: 0, channelCount: 1,
      processorOptions: {inputSampleRate: audioCtx.sampleRate, targetSampleRate: TARGET_SR, blockLen: SAMPLES_PER_BLOCK}
    })
    source.connect(workletNode)

    workletNode.port.onmessage = (ev: MessageEvent) => {
      const {type, payload} = ev.data || {}
      if (type === 'block-int16') {
        // payload ist ein ArrayBuffer mit Int16 PCM @ 16kHz, 1s => 32.000 Bytes
        const int16 = new Int16Array(payload)
        const wavBlob = pcmToWavBlob(int16, TARGET_SR, CHANNELS)
        const filename = `seg_${String(seq).padStart(6, '0')}_${new Date().toISOString().replace(/[:.]/g, '-')}.wav`
        queue.value.push({seq: seq++, wav: wavBlob, filename, createdAt: Date.now()})
        pump()
      }
    }

    isRunning.value = true
    sent.value = 0
    startTs.value = performance.now()
    elapsed.value = 0
    tick = window.setInterval(() => {
      if (startTs.value) elapsed.value = performance.now() - startTs.value
      pump()
    }, 150)
  } catch (e: unknown) {
    error.value = (e as Error)?.message || String((e as Error))
    await stop()
  }
}

async function stop() {
  try {
    workletNode?.disconnect()
  } catch (e) {
    console.log(e)
  }
  workletNode = null
  try {
    stream?.getTracks().forEach(t => t.stop())
  } catch (e) {
    console.log(e)
  }
  stream = null
  try {
    await audioCtx?.close()
  } catch (e) {
    console.log(e)
  }
  audioCtx = null
  isRunning.value = false
  if (tick) {
    clearInterval(tick);
    tick = null
  }
  status.value = 'Beendet.'
}

/** WAV-Erzeugung: Header + PCM-Daten (S16LE, mono, 16k) */
function pcmToWavBlob(pcm: Int16Array, sampleRate: number, channels: number): Blob {
  const byteRate = sampleRate * channels * BYTES_PER_SAMPLE
  const blockAlign = channels * BYTES_PER_SAMPLE
  const dataSize = pcm.length * BYTES_PER_SAMPLE
  const buffer = new ArrayBuffer(44 + dataSize)
  const view = new DataView(buffer)

  // RIFF chunk descriptor
  writeString(view, 0, 'RIFF')
  view.setUint32(4, 36 + dataSize, true)   // ChunkSize
  writeString(view, 8, 'WAVE')
  // fmt subchunk
  writeString(view, 12, 'fmt ')
  view.setUint32(16, 16, true)             // Subchunk1Size (PCM)
  view.setUint16(20, 1, true)              // AudioFormat (1=PCM)
  view.setUint16(22, channels, true)       // NumChannels
  view.setUint32(24, sampleRate, true)     // SampleRate
  view.setUint32(28, byteRate, true)       // ByteRate
  view.setUint16(32, blockAlign, true)     // BlockAlign
  view.setUint16(34, 16, true)             // BitsPerSample
  // data subchunk
  writeString(view, 36, 'data')
  view.setUint32(40, dataSize, true)

  // PCM Daten anhängen (Little Endian)
  let offset = 44
  for (let i = 0; i < pcm.length; i++, offset += 2) {
    view.setInt16(offset, (pcm[i] as number), true)
  }
  return new Blob([view], {type: 'audio/wav'})
}

function writeString(view: DataView, offset: number, str: string) {
  for (let i = 0; i < str.length; i++) view.setUint8(offset + i, str.charCodeAt(i))
}

/** Upload-Pipeline */
function pump() {
  while (inFlight < CONCURRENCY && queue.value.length) {
    const item = queue.value.shift()!
    uploadItem(item, 0).catch(() => {
    })
  }
}

const i18n = useI18n();

async function uploadItem(item: Item, attempt: number): Promise<void> {
  inFlight++
  try {
    const form = new FormData()
    // Der Browser setzt Content-Type inkl. Boundary automatisch – NICHT selbst setzen!
    form.append('file', item.wav, item.filename)
    // Optional: zusätzliche Felder
    form.append('seq', String(item.seq))
    form.append('sample_rate', String(TARGET_SR))
    form.append('channels', String(CHANNELS))
    form.append('duration_ms', '1000')

    const resp = await fetch(UPLOAD_URL, {
      method: 'POST',
      headers: {},
      body: form
    })
    if (!resp.ok) throw new Error(`HTTP ${resp.status} ${resp.statusText}`)
    sent.value++
  } catch (err: unknown) {
    if (attempt + 1 < MAX_RETRY) {
      const delay = 300 * Math.pow(2, attempt)
      await new Promise(r => setTimeout(r, delay))
      return uploadItem(item, attempt + 1)
    } else {
      error.value = `${i18n.t('audio-component.error')} (seq=${item.seq}): ${(err as Error)?.message || (err as Error)}`
      // Optional: Retry später
      // queue.value.unshift(item)
    }
  } finally {
    inFlight--
    pump()
  }
}

/** Inline-AudioWorklet: 16k Resampling + 1s Framing + Int16 */
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
  `
  const blob = new Blob([code], {type: 'application/javascript'})
  return URL.createObjectURL(blob)
}
</script>
