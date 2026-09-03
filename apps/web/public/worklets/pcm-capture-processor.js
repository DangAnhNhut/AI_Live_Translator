class PcmCaptureProcessor extends AudioWorkletProcessor {
  process(inputs) {
    const input = inputs[0];
    if (input && input.length > 0 && input[0].length > 0) {
      const channels = input.map((channel) => new Float32Array(channel));
      this.port.postMessage(
        { channels },
        channels.map((channel) => channel.buffer),
      );
    }
    return true;
  }
}

registerProcessor("pcm-capture-processor", PcmCaptureProcessor);
