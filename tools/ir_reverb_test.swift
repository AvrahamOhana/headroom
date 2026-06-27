//
//  ir_reverb_test.swift
//  Headless verification for ReverbIRBlock's single-FFT overlap-save convolution.
//
//  Replicates the EXACT vDSP overlap-save math used by ReverbIRBlock (same N / B /
//  vDSP_fft_zrip / vDSP_ctoz / vDSP_ztoc / vDSP_zvmul calls) and compares its block
//  output against a DIRECT time-domain convolution reference:
//    (a) impulse  -> output must equal the IR taps
//    (b) sine+noise -> output must equal the direct convolution
//  Input is fed in ODD-sized chunks to exercise the 1-block FIFO decoupling.
//
//  Run:  swift tools/ir_reverb_test.swift
//
//  It sweeps candidate vDSP scale constants and reports which one gives maxErr < 1e-3.
//

import Foundation
import Accelerate

// ---- Fixed transform geometry (must match ReverbIRBlock exactly) ----
let log2N: vDSP_Length = 16
let N = 1 << 16            // 65536
let halfN = N / 2          // 32768
let B = 512                // hop
let maxIR = N - B          // 65024

let setup = vDSP_create_fftsetup(log2N, FFTRadix(kFFTRadix2))!

// ---- Preallocated transform buffers (mirror the block's preallocated state) ----
func makeBuf(_ c: Int) -> UnsafeMutablePointer<Float> {
    let p = UnsafeMutablePointer<Float>.allocate(capacity: c)
    p.initialize(repeating: 0, count: c)
    return p
}
let Hr = makeBuf(halfN), Hi = makeBuf(halfN)
let window = makeBuf(N)
let Xr = makeBuf(halfN), Xi = makeBuf(halfN)
let Yr = makeBuf(halfN), Yi = makeBuf(halfN)
let timeOut = makeBuf(N)
let irPad = makeBuf(N)
var inBuf = [Float](repeating: 0, count: B)
var outBuf = [Float](repeating: 0, count: B)

// ---- Mutable running state ----
var fillPos = 0
var readPos = 0
var irLen = 0
var SCALE: Float = 1.0 / Float(4 * N)   // candidate under test (overwritten by sweep)

// ---- Load IR: zero-pad to N, single forward real FFT -> H ----
func setIR(_ taps: [Float]) {
    let n = min(taps.count, maxIR)
    for i in 0..<N { irPad[i] = i < n ? taps[i] : 0 }
    var split = DSPSplitComplex(realp: Hr, imagp: Hi)
    irPad.withMemoryRebound(to: DSPComplex.self, capacity: halfN) {
        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfN))
    }
    vDSP_fft_zrip(setup, &split, 1, log2N, FFTDirection(kFFTDirection_Forward))
    irLen = n
}

func clearState() {
    for i in 0..<N { window[i] = 0 }
    for i in 0..<B { inBuf[i] = 0; outBuf[i] = 0 }
    fillPos = 0; readPos = 0
}

// ---- One overlap-save conv step: window<-newBlock, X=FFT(window), Y=X*H, ifft, last B ----
func convStep() {
    inBuf.withUnsafeBufferPointer { ib in
        memmove(window, window + B, (N - B) * MemoryLayout<Float>.size)
        memcpy(window + (N - B), ib.baseAddress!, B * MemoryLayout<Float>.size)
    }
    var xs = DSPSplitComplex(realp: Xr, imagp: Xi)
    window.withMemoryRebound(to: DSPComplex.self, capacity: halfN) {
        vDSP_ctoz($0, 2, &xs, 1, vDSP_Length(halfN))
    }
    vDSP_fft_zrip(setup, &xs, 1, log2N, FFTDirection(kFFTDirection_Forward))

    // Y = X * H. Bins 1..halfN-1 are complex; bin 0 packs DC (realp) & Nyquist (imagp) as reals.
    Yr[0] = Xr[0] * Hr[0]
    Yi[0] = Xi[0] * Hi[0]
    var xc = DSPSplitComplex(realp: Xr + 1, imagp: Xi + 1)
    var hc = DSPSplitComplex(realp: Hr + 1, imagp: Hi + 1)
    var yc = DSPSplitComplex(realp: Yr + 1, imagp: Yi + 1)
    vDSP_zvmul(&xc, 1, &hc, 1, &yc, 1, vDSP_Length(halfN - 1), 1)

    var ys = DSPSplitComplex(realp: Yr, imagp: Yi)
    vDSP_fft_zrip(setup, &ys, 1, log2N, FFTDirection(kFFTDirection_Inverse))
    timeOut.withMemoryRebound(to: DSPComplex.self, capacity: halfN) {
        vDSP_ztoc(&ys, 1, $0, 2, vDSP_Length(halfN))
    }
    let sc = SCALE
    for j in 0..<B { outBuf[j] = timeOut[N - B + j] * sc }
}

// ---- Run the FIFO-decoupled convolution over an input, in odd-sized chunks ----
// Returns wetOut where wetOut[B + n] == (x conv h)[n]  (B-sample FIFO latency).
func runFIFO(_ x: [Float]) -> [Float] {
    clearState()
    var wet = [Float](repeating: 0, count: x.count)
    let chunks = [333, 1, 100, 777, 512, 5, 999, 64, 200]
    var idx = 0, ci = 0
    while idx < x.count {
        let c = min(chunks[ci % chunks.count], x.count - idx)
        ci += 1
        for k in 0..<c {
            let i = idx + k
            inBuf[fillPos] = x[i]; fillPos += 1
            wet[i] = outBuf[readPos]; readPos += 1
            if fillPos >= B { convStep(); fillPos = 0; readPos = 0 }
        }
        idx += c
    }
    return wet
}

// ---- Direct time-domain convolution reference ----
func directConv(_ x: [Float], _ ir: [Float]) -> [Float] {
    var y = [Float](repeating: 0, count: x.count)
    let L = ir.count
    for nIdx in 0..<x.count {
        var acc: Float = 0
        let kMax = min(L - 1, nIdx)
        for k in 0...kMax { acc += ir[k] * x[nIdx - k] }
        y[nIdx] = acc
    }
    return y
}

func maxErr(_ wet: [Float], _ ref: [Float]) -> Float {
    // wet[B + n] should equal ref[n]; compare over the settled region.
    var e: Float = 0
    let last = wet.count - B
    for n in 0..<last { e = max(e, abs(wet[B + n] - ref[n])) }
    return e
}

// ====================  Build a short test IR (~1500 taps)  ====================
let irTaps = 1500
var ir = [Float](repeating: 0, count: irTaps)
var seed: UInt64 = 0x9E3779B97F4A7C15
func rnd() -> Float {            // deterministic LCG in [-1,1]
    seed = seed &* 6364136223846793005 &+ 1442695040888963407
    return Float(Int32(truncatingIfNeeded: seed >> 16)) / Float(Int32.max)
}
for k in 0..<irTaps { ir[k] = rnd() * expf(-Float(k) / 350.0) }
ir[0] = 1.0
// L2-normalize so convolution output stays ~unit-magnitude (keeps abs error meaningful).
var energy: Float = 0
for v in ir { energy += v * v }
let norm = 1.0 / sqrtf(energy)
for k in 0..<irTaps { ir[k] *= norm }

setIR(ir)

// ====================  Test signals  ====================
let total = 10000
// (a) impulse
var impulse = [Float](repeating: 0, count: total); impulse[0] = 1
// (b) sine + noise
var mix = [Float](repeating: 0, count: total)
let sr: Float = 48000, f: Float = 220
for i in 0..<total { mix[i] = 0.7 * sinf(2 * .pi * f * Float(i) / sr) + 0.15 * rnd() }

let refImpulse = directConv(impulse, ir)
let refMix = directConv(mix, ir)

// ====================  Sweep candidate scale constants  ====================
let candidates: [(String, Float)] = [
    ("1/N",     1.0 / Float(N)),
    ("1/(2N)",  1.0 / Float(2 * N)),
    ("1/(4N)",  1.0 / Float(4 * N)),
    ("1/(8N)",  1.0 / Float(8 * N)),
    ("2/N",     2.0 / Float(N)),
]

print("N=\(N)  B=\(B)  halfN=\(halfN)  irTaps=\(irTaps)  total=\(total)")
print("scale        impulse-maxErr     sine+noise-maxErr")

var best: (String, Float, Float, Float)? = nil   // name, scale, eImp, eMix
for (name, sc) in candidates {
    SCALE = sc
    let eImp = maxErr(runFIFO(impulse), refImpulse)
    let eMix = maxErr(runFIFO(mix), refMix)
    print("  \(name.padding(toLength: 8, withPad: " ", startingAt: 0))   \(eImp)\t\(eMix)")
    let worst = max(eImp, eMix)
    if best == nil || worst < max(best!.2, best!.3) { best = (name, sc, eImp, eMix) }
}

if let b = best {
    let worst = max(b.2, b.3)
    print("\nBEST: \(b.0) = \(b.1)   impulse=\(b.2)  sine+noise=\(b.3)")
    if worst < 1e-3 {
        print("PASS  (maxErr \(worst) < 1e-3)  -> hardcode irScale = \(b.0)")
        exit(0)
    } else {
        print("FAIL  (maxErr \(worst) >= 1e-3)")
        exit(1)
    }
}
exit(1)
