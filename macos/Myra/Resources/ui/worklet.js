// Audio worklets for Myra: microphone capture -> 24 kHz Int16, and 24 kHz playback.
const MODEL_RATE = 24000;

class MyraCapture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.step = sampleRate / MODEL_RATE; // input samples per output sample
    this.pos = 0;                         // fractional read position into `carry`
    this.carry = new Float32Array(0);
    this.out = new Int16Array(480);       // 20 ms at 24 kHz
    this.outLen = 0;
    this.levelAcc = 0;
    this.levelN = 0;
  }
  process(inputs) {
    const input = inputs[0] && inputs[0][0];
    if (!input) return true;
    const buf = new Float32Array(this.carry.length + input.length);
    buf.set(this.carry, 0);
    buf.set(input, this.carry.length);
    let pos = this.pos;
    while (pos + 1 < buf.length) {
      const i = Math.floor(pos);
      const f = pos - i;
      const s = buf[i] * (1 - f) + buf[i + 1] * f;
      const c = Math.max(-1, Math.min(1, s));
      this.out[this.outLen++] = c < 0 ? c * 32768 : c * 32767;
      this.levelAcc += s * s;
      this.levelN++;
      if (this.outLen === this.out.length) {
        const chunk = this.out.slice(0);
        this.port.postMessage({ pcm: chunk.buffer, level: Math.sqrt(this.levelAcc / this.levelN) }, [chunk.buffer]);
        this.outLen = 0;
        this.levelAcc = 0;
        this.levelN = 0;
      }
      pos += this.step;
    }
    const keepFrom = Math.floor(pos);
    this.carry = buf.slice(keepFrom);
    this.pos = pos - keepFrom;
    return true;
  }
}

class MyraPlayer extends AudioWorkletProcessor {
  constructor() {
    super();
    this.step = MODEL_RATE / sampleRate;
    this.chunks = [];
    this.buffered = 0;      // samples at 24 kHz waiting
    this.cur = null;
    this.curPos = 0;
    this.prev = 0;
    this.playing = false;
    this.minStart = MODEL_RATE * 0.12; // 120 ms jitter buffer after an underrun
    this.port.onmessage = (e) => {
      if (e.data === 'reset') { this.chunks = []; this.buffered = 0; this.cur = null; this.playing = false; return; }
      const chunk = new Float32Array(e.data);
      this.chunks.push(chunk);
      this.buffered += chunk.length;
    };
  }
  next() {
    if (this.cur && this.curPos < this.cur.length) {
      return this.cur[this.curPos++];
    }
    this.cur = this.chunks.shift() || null;
    this.curPos = 0;
    if (!this.cur) return null;
    return this.cur[this.curPos++];
  }
  process(_inputs, outputs) {
    const out = outputs[0][0];
    if (!this.playing && this.buffered >= this.minStart) this.playing = true;
    let level = 0;
    for (let i = 0; i < out.length; i++) {
      if (!this.playing) { out[i] = 0; continue; }
      // linear upsampling from 24 kHz
      this.frac = (this.frac || 0) + this.step;
      while (this.frac >= 1) {
        const s = this.next();
        if (s === null) { this.playing = false; this.buffered = 0; break; }
        this.buffered--;
        this.prev = this.nextVal === undefined ? s : this.nextVal;
        this.nextVal = s;
        this.frac -= 1;
      }
      const v = this.prev * (1 - this.frac) + (this.nextVal || 0) * this.frac;
      out[i] = this.playing ? v : 0;
      level += out[i] * out[i];
    }
    for (let ch = 1; ch < outputs[0].length; ch++) outputs[0][ch].set(out);
    this.levelFrames = (this.levelFrames || 0) + 1;
    if (this.levelFrames % 8 === 0) this.port.postMessage({ level: Math.sqrt(level / out.length) });
    return true;
  }
}

registerProcessor('myra-capture', MyraCapture);
registerProcessor('myra-player', MyraPlayer);
