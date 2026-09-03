import type { TargetLanguage } from "../realtime/translation.ts";

export const HOST_SOURCE_LANGUAGE = {
  code: "vi",
  label: "Vietnamese",
  readOnly: true,
} as const;

export const HOST_TARGET_LANGUAGE_OPTIONS: ReadonlyArray<{
  code: TargetLanguage;
  label: string;
}> = [
  { code: "en", label: "English" },
  { code: "ja", label: "Japanese" },
  { code: "ko", label: "Korean" },
  { code: "zh-CN", label: "Chinese (Simplified)" },
  { code: "th", label: "Thai" },
  { code: "fr", label: "French" },
  { code: "de", label: "German" },
  { code: "es", label: "Spanish" },
];

export type HostTranslationSelection = {
  targetLanguage: TargetLanguage;
  locked: boolean;
};

export function createHostTranslationSelection(): HostTranslationSelection {
  return { targetLanguage: "en", locked: false };
}

export function selectHostTargetLanguage(
  selection: HostTranslationSelection,
  targetLanguage: TargetLanguage,
): HostTranslationSelection {
  if (selection.locked || selection.targetLanguage === targetLanguage) {
    return selection;
  }
  return { targetLanguage, locked: false };
}

export function lockHostTranslationSelection(
  selection: HostTranslationSelection,
): HostTranslationSelection {
  return selection.locked ? selection : { ...selection, locked: true };
}

export function unlockHostTranslationSelection(
  selection: HostTranslationSelection,
): HostTranslationSelection {
  return selection.locked ? { ...selection, locked: false } : selection;
}
