export function isUnsupportedMediaError(error: unknown, mediaError: MediaError | null): boolean {
  const message = error instanceof Error ? error.message : String(error);
  return mediaError?.code === MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED || message.includes("not supported");
}

export function mediaErrorMessage(error: unknown, mediaError: MediaError | null = null): string {
  const message = error instanceof Error ? error.message : String(error);

  if (isUnsupportedMediaError(error, mediaError)) {
    return "Could not play that file. The Rust media stream was rejected by the WebView.";
  }

  if (mediaError) {
    const details =
      mediaError.code === MediaError.MEDIA_ERR_ABORTED
        ? "Playback was aborted."
        : mediaError.code === MediaError.MEDIA_ERR_NETWORK
          ? "The local file could not be read."
          : mediaError.code === MediaError.MEDIA_ERR_DECODE
            ? "The MP3 could not be decoded."
            : "The media file is not supported.";
    return `${details} ${message}`;
  }

  return message;
}
