<!-- UI adapter (driving side): turns user input into a use case call. Domain and application never import
     Vue (ADR 0005); the store is injected by the composition root in main.ts. -->
<script setup lang="ts">
import { ref, useId } from "vue";
import { completeExportUseCase, type ArtifactStore } from "../application/complete-export.ts";
import { startExport } from "../domain/export-job.ts";

const props = defineProps<{ store: ArtifactStore }>();

const JOB_ID = /^[A-Za-z0-9_-]{1,64}$/;
const jobId = ref("");
const content = ref("");
const status = ref("");
const saving = ref(false);
const jobInputId = useId();
const contentInputId = useId();

async function submit(): Promise<void> {
  if (!JOB_ID.test(jobId.value) || content.value.length === 0) {
    status.value = "Enter a job id (letters, digits, - or _) and some content.";
    return;
  }
  saving.value = true;
  status.value = "Saving…";
  try {
    const ready = await completeExportUseCase(props.store, startExport({ kind: "queued", id: jobId.value }), content.value);
    status.value = `Saved as ${ready.artifactKey}`;
  } catch {
    status.value = "The export could not be saved.";
  } finally {
    saving.value = false;
  }
}
</script>

<template>
  <main>
    <h1>Complete an export</h1>
    <form
      novalidate
      @submit.prevent="submit"
    >
      <label :for="jobInputId">Job id
        <input
          :id="jobInputId"
          v-model="jobId"
          name="jobId"
          autocomplete="off"
        >
      </label>
      <label :for="contentInputId">Content
        <textarea
          :id="contentInputId"
          v-model="content"
          name="content"
          rows="4"
        />
      </label>
      <button
        type="submit"
        :disabled="saving"
      >
        Complete export
      </button>
    </form>
    <p role="status">
      {{ status }}
    </p>
  </main>
</template>
