<template>
  <q-layout view="hHh lpr fFf">
    <div id="background">
      <div id="blur">

        <!-- Header -->
        <q-header elevated class="bg-secondary text-primary">
          <q-toolbar>
            <!-- Title -->
            <q-toolbar-title class="row">
              <div class="col text-bold q-my-auto q-pl-lg text-h3">
                <div class="row">
                  {{ $t('app.title') }}
                </div>
              </div>

              <!-- Logo -->
              <div class="row justify-evenly items-centers">
                <div class="col">
                  <img
                    src="https://upload.wikimedia.org/wikipedia/commons/7/7f/DHBW_CAS_Logo.png"
                    :alt="$t('app.institution')"
                    class="toolbar-logo"
                  >
                </div>
              </div>
            </q-toolbar-title>
          </q-toolbar>
        </q-header>

        <!-- Page Content -->
        <q-page-container>
          <router-view/>
        </q-page-container>
      </div>
    </div>
  </q-layout>
</template>

<script setup lang="ts"></script>
