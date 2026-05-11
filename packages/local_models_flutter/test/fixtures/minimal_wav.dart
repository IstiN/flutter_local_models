import 'dart:typed_data';

/// Mono 16-bit PCM WAV (16 kHz), one zero sample — valid for STT path checks.
Uint8List minimalWavMono16k() {
  const sampleRate = 16000;
  const bitsPerSample = 16;
  const numChannels = 1;
  const numSamples = 4;
  final byteRate = sampleRate * numChannels * bitsPerSample ~/ 8;
  final blockAlign = numChannels * bitsPerSample ~/ 8;
  final dataSize = numSamples * blockAlign;
  final chunkSize = 36 + dataSize;

  final b = BytesBuilder();
  void w32(int v) {
    b.addByte(v & 0xff);
    b.addByte((v >> 8) & 0xff);
    b.addByte((v >> 16) & 0xff);
    b.addByte((v >> 24) & 0xff);
  }

  void w16(int v) {
    b.addByte(v & 0xff);
    b.addByte((v >> 8) & 0xff);
  }

  b.add('RIFF'.codeUnits);
  w32(chunkSize);
  b.add('WAVE'.codeUnits);
  b.add('fmt '.codeUnits);
  w32(16);
  w16(1);
  w16(numChannels);
  w32(sampleRate);
  w32(byteRate);
  w16(blockAlign);
  w16(bitsPerSample);
  b.add('data'.codeUnits);
  w32(dataSize);
  for (var i = 0; i < numSamples; i++) {
    w16(0);
  }
  return Uint8List.fromList(b.toBytes());
}
