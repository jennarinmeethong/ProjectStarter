// UI adapter (driving side): React Native screen that turns input into a use case call. Domain and
// application never import React Native (ADR 0005); the store is injected by Root.tsx.
import { useState, type JSX } from "react";
import { Pressable, StyleSheet, Text, TextInput, View } from "react-native";
import { completeExportUseCase, type ArtifactStore } from "../application/complete-export.ts";
import { startExport } from "../domain/export-job.ts";

const JOB_ID = /^[A-Za-z0-9_-]{1,64}$/;

export function App({ store }: { readonly store: ArtifactStore }): JSX.Element {
  const [jobId, setJobId] = useState("");
  const [content, setContent] = useState("");
  const [status, setStatus] = useState("");
  const [saving, setSaving] = useState(false);

  async function submit(): Promise<void> {
    if (!JOB_ID.test(jobId) || content.length === 0) {
      setStatus("Enter a job id (letters, digits, - or _) and some content.");
      return;
    }
    setSaving(true);
    setStatus("Saving…");
    try {
      const ready = await completeExportUseCase(store, startExport({ kind: "queued", id: jobId }), content);
      setStatus(`Saved as ${ready.artifactKey}`);
    } catch {
      setStatus("The export could not be saved.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <View style={styles.screen} role="main">
      <Text role="heading" aria-level={1} style={styles.title}>Complete an export</Text>
      <Text nativeID="job-id-label">Job id</Text>
      <TextInput aria-labelledby="job-id-label" value={jobId} onChangeText={setJobId} autoCapitalize="none" style={styles.input} />
      <Text nativeID="content-label">Content</Text>
      <TextInput aria-labelledby="content-label" value={content} onChangeText={setContent} multiline style={styles.input} />
      <Pressable role="button" aria-label="Complete export" disabled={saving} onPress={() => { void submit(); }} style={styles.button}>
        <Text style={styles.buttonText}>Complete export</Text>
      </Pressable>
      <Text role="status">{status}</Text>
    </View>
  );
}

const styles = StyleSheet.create({
  screen: { padding: 16, gap: 8 },
  title: { fontSize: 24, fontWeight: "600" },
  input: { borderWidth: 1, borderColor: "#555", padding: 8 },
  button: { backgroundColor: "#1f4fbf", padding: 12, alignItems: "center" },
  buttonText: { color: "#ffffff" },
});
