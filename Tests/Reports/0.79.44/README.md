# 0.79.44 targeted SMP4 integration

Five accepted bounded scenarios on the existing technical image: synthetic
DISPLAYD baseline on bootfb and Virtio; Desktop bootfb before/after optimization;
final Desktop Virtio. Four CPUs, KVM, 1024 MB, 1280x720, no network. Final native
artifact hash matches the build. bootfb performance records predate only extra
diagnostic counters. Full raw inputs, captures, hashes, restored staging proof
and reproduction helpers: ExFiles/Reference/GFX/0.79.44/software-20260921.

Desktop smoke uses AppDefaults/MemView, coalesced move/resize, two producers,
idle, service reconstruction, close and shared color/image scaling. No new
test group. No real NVIDIA, physical visibility or input-latency qualification.
The reused base image displays historical release 0.79.38; this is no release
installation proof. See Docs/Desktop/GrafikIntegration07944.txt/.json.
