export class StreamingLinearResampler {
  private readonly sourceFramesPerOutputFrame: number;
  private retained = new Float32Array(0);
  private sourcePosition = 0;

  constructor(
    inputSampleRate: number,
    outputSampleRate: number,
  ) {
    if (
      !Number.isFinite(inputSampleRate) ||
      inputSampleRate <= 0 ||
      !Number.isFinite(outputSampleRate) ||
      outputSampleRate <= 0
    ) {
      throw new Error("Audio sample rates must be positive finite numbers.");
    }
    this.sourceFramesPerOutputFrame = inputSampleRate / outputSampleRate;
  }

  process(input: Float32Array): Float32Array {
    if (input.length === 0) {
      return new Float32Array(0);
    }

    const source = new Float32Array(this.retained.length + input.length);
    source.set(this.retained);
    source.set(input, this.retained.length);

    const output: number[] = [];
    while (this.sourcePosition < source.length) {
      const leftIndex = Math.floor(this.sourcePosition);
      const fraction = this.sourcePosition - leftIndex;
      if (leftIndex >= source.length) {
        break;
      }
      if (leftIndex + 1 >= source.length && fraction > Number.EPSILON) {
        break;
      }

      const left = source[leftIndex];
      const right = source[leftIndex + 1] ?? left;
      output.push(left + (right - left) * fraction);
      this.sourcePosition += this.sourceFramesPerOutputFrame;
    }

    const consumedFrames = Math.min(
      Math.floor(this.sourcePosition),
      source.length,
    );
    this.retained = source.slice(consumedFrames);
    this.sourcePosition -= consumedFrames;

    return Float32Array.from(output);
  }

  reset(): void {
    this.retained = new Float32Array(0);
    this.sourcePosition = 0;
  }
}
