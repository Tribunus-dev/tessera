import Foundation
#if canImport(Metal)
import Metal
#endif
#if canImport(Darwin)
import Darwin
#endif

/// Mac-native hardware capacity probe + community model-fit catalog. Ports
/// `tessera-studio-linux/src/core/ops/Capacity.cpp` to macOS: sysctl for
/// CPU/RAM, Metal for GPU (no /proc or lspci). The fit math and the 10-model
/// catalog are identical to the Linux version.
public struct TesseraLocalCapacity: Sendable {
    public struct GPUInfo: Sendable {
        public var name: String
        public var api: String       // "metal" on macOS
        public var vramMB: UInt64
        public var isEgpu: Bool
        public init(name: String, api: String, vramMB: UInt64, isEgpu: Bool) {
            self.name = name; self.api = api; self.vramMB = vramMB; self.isEgpu = isEgpu
        }
    }

    public var cpuModel: String = ""
    public var cpuCores: Int = 0
    public var cpuISA: String = "arm64"
    public var ramTotalMB: UInt64 = 0
    public var ramAvailMB: UInt64 = 0
    public var igpu: GPUInfo?
    public var bandwidthGBs: Double = 60.0

    public init() {}
}

public struct TesseraModelFit: Sendable, Identifiable, Hashable {
    public let id: String
    public let sizeMB: UInt64
    public let quant: String
    public let fitsRAM: Bool
    public let estTokS: Double
    public let badge: String       // "green" | "amber" | "red"
}

public enum TesseraCapacity {
    /// Probe the host. Mac-native: sysctl for CPU/RAM, Metal for GPU.
    /// RAM-available is approximate (Darwin has no direct /proc/meminfo
    /// equivalent; vm_statistics gives pages-free, which we convert).
    public static func gather() -> TesseraLocalCapacity {
        var c = TesseraLocalCapacity()
        c.cpuModel = sysctl("machdep.cpu.brand_string").isEmpty
            ? sysctl("hw.optional.arm64")
                .isEmpty ? "Apple Silicon" : "Apple Silicon"
            : sysctl("machdep.cpu.brand_string")
        c.cpuCores = ProcessInfo.processInfo.processorCount
        #if canImport(Darwin)
        c.cpuISA = "arm64"  // Darwin on Apple Silicon; Intel Macs report x86-64
        // Total RAM via sysctl hw.memsize (bytes).
        if let bytes = UInt64(sysctl("hw.memsize")) {
            c.ramTotalMB = bytes / (1024 * 1024)
        }
        // Approximate available RAM from vm_statistics.
        c.ramAvailMB = approximateFreeMB()
        #endif

        #if canImport(Metal)
        if let device = MTLCopyAllDevices().first {
            c.igpu = .init(
                name: device.name,
                api: "metal",
                vramMB: UInt64(device.recommendedMaxWorkingSetSize / (1024 * 1024)),
                isEgpu: device.isRemovable
            )
            // Apple Silicon unified-memory bandwidth (M1=68, M2=100, M3=150 GB/s
            // nominal). recommendedMaxWorkingSetSize already reflects the pool.
            c.bandwidthGBs = estimateBandwidthGBs(deviceName: device.name)
        }
        #endif
        return c
    }

    /// Estimate tok/s from memory bandwidth and model size. Ported verbatim
    /// from the Linux Capacity.cpp; the dGPU VRAM fast-path maps to Metal's
    /// working set on Mac (kept as a single-bandwidth path here).
    public static func estimateTokensPerSec(_ cap: TesseraLocalCapacity, modelBytes: UInt64) -> Double {
        guard modelBytes > 0 else { return 0 }
        var bw = cap.bandwidthGBs * 1e9
        if let igpu = cap.igpu, igpu.vramMB * 1024 * 1024 >= modelBytes {
            // The model fits in the GPU working set - use the full bandwidth.
            bw = cap.bandwidthGBs * 1e9
        }
        return bw / Double(modelBytes)
    }

    /// The 10-model community GGUF fit catalog. Same models + sizes as the
    /// Linux version so users see a consistent catalog across platforms.
    public static func communityFits(_ cap: TesseraLocalCapacity) -> [TesseraModelFit] {
        struct Raw { let id: String; let mb: UInt64; let q: String }
        let raws: [Raw] = [
            .init(id: "gemma-3-4b Q4_0", mb: 2400, q: "q4_0"),
            .init(id: "gemma-4-12b Q4_0", mb: 6500, q: "q4_0"),
            .init(id: "llama-3.1-8b Q4_K_M", mb: 4900, q: "q4_k_m"),
            .init(id: "mistral-7b Q4_K_M", mb: 4300, q: "q4_k_m"),
            .init(id: "qwen2.5-7b Q4_K_M", mb: 4700, q: "q4_k_m"),
            .init(id: "qwen2.5-14b Q4_K_M", mb: 8500, q: "q4_k_m"),
            .init(id: "deepseek-coder-6.7b Q4", mb: 3800, q: "q4_0"),
            .init(id: "phi-3-mini 3.8b Q4", mb: 2300, q: "q4_k_m"),
            .init(id: "gemma-3-27b Q4_0", mb: 15000, q: "q4_0"),
            .init(id: "llama-3.1-70b Q4_K_M", mb: 42000, q: "q4_k_m"),
        ]
        let avail = cap.ramAvailMB > 0
            ? cap.ramAvailMB
            : (cap.ramTotalMB > 0 ? cap.ramTotalMB * 70 / 100 : 8192)
        return raws.map { raw in
            let tok = estimateTokensPerSec(cap, modelBytes: raw.mb * 1024 * 1024)
            let fits = raw.mb + 800 < avail
            let badge = fits ? (tok > 18 ? "green" : "amber") : "red"
            return TesseraModelFit(
                id: raw.id, sizeMB: raw.mb, quant: raw.q,
                fitsRAM: fits, estTokS: tok, badge: badge
            )
        }
    }

    // MARK: - Helpers

    private static func sysctl(_ name: String) -> String {
        var size = 0
        if sysctlbyname(name, nil, &size, nil, 0) != 0 { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        if sysctlbyname(name, &buffer, &size, nil, 0) != 0 { return "" }
        return String(cString: buffer)
    }

    private static func approximateFreeMB() -> UInt64 {
        #if canImport(Darwin)
        var pageSize = vm_size_t(0)
        withUnsafeMutablePointer(to: &pageSize) { ptr in
            _ = host_page_size(mach_host_self(), ptr)
        }
        var stats = vm_statistics()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_VM_INFO, intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS, pageSize > 0 else { return 0 }
        let free = UInt64(stats.free_count) * UInt64(pageSize)
        return free / (1024 * 1024)
        #else
        return 0
        #endif
    }

    /// Rough nominal bandwidth by Apple Silicon family. Conservative defaults;
    /// real measurement would need a microbenchmark.
    private static func estimateBandwidthGBs(deviceName: String) -> Double {
        let n = deviceName.lowercased()
        if n.contains("m3") || n.contains("m4") { return 150.0 }
        if n.contains("m2") { return 100.0 }
        if n.contains("m1") { return 68.0 }
        return 68.0
    }
}
