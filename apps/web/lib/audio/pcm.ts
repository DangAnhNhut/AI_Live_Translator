export function downmixToMono(
  channels: readonly Float32Array[],
): Float32Array {
  if (channels.length === 0) {
    return new Float32Array(0);
  }

  const frameCount = channels[0].length;
  if (channels.some((channel) => channel.length !== frameCount)) {
    throw new Error("Audio channels must contain the same number of frames.");
  }

  const mono = new Float32Array(frameCount);
  for (const channel of channels) {
    for (let index = 0; index < frameCount; index += 1) {
      mono[index] += channel[index] / channels.length;
    }
  }
  return mono;
}

export function float32ToPcm16Le(samples: Float32Array): ArrayBuffer {
  const output = new ArrayBuffer(samples.length * Int16Array.BYTES_PER_ELEMENT);
  const view = new DataView(output);

  for (let index = 0; index < samples.length; index += 1) {
    const clamped = Math.max(-1, Math.min(1, samples[index]));
    const scaled = Math.trunc(clamped < 0 ? clamped * 32768 : clamped * 32767);
    view.setInt16(index * Int16Array.BYTES_PER_ELEMENT, scaled, true);
  }

  return output;
}

export class PcmChunkAccumulator {
  private readonly chunkSizeBytes: number;
  private pending = new Uint8Array(0);

  constructor(chunkSizeBytes: number) {
    if (!Number.isInteger(chunkSizeBytes) || chunkSizeBytes <= 0) {
      throw new Error("PCM chunk size must be a positive integer.");
    }
    this.chunkSizeBytes = chunkSizeBytes;
  }

  push(buffer: ArrayBuffer): ArrayBuffer[] {
    if (buffer.byteLength === 0) {
      return [];
    }

    const incoming = new Uint8Array(buffer);
    const combined = new Uint8Array(this.pending.length + incoming.length);
    combined.set(this.pending);
    combined.set(incoming, this.pending.length);

    const chunks: ArrayBuffer[] = [];
    let offset = 0;
    while (combined.length - offset >= this.chunkSizeBytes) {
      chunks.push(combined.slice(offset, offset + this.chunkSizeBytes).buffer);
      offset += this.chunkSizeBytes;
    }

    this.pending = combined.slice(offset);
    return chunks;
  }

  flush(): ArrayBuffer | null {
    if (this.pending.length === 0) {
      return null;
    }

    const remainder = this.pending.buffer;
    this.pending = new Uint8Array(0);
    return remainder;
  }

  reset(): void {
    this.pending = new Uint8Array(0);
  }
}
