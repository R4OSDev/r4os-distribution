#![allow(dead_code)]
use std::cell::RefCell;
#[derive(Default)]
struct Allocator {
    calls: usize,
    fail_at: Option<usize>,
    live: Vec<(u64, u16)>,
}
thread_local! { static ALLOC: RefCell<Allocator> = RefCell::new(Allocator::default()); }
fn allocate(count: u16) -> Option<u64> {
    ALLOC.with_borrow_mut(|a| {
        let call = a.calls;
        a.calls += 1;
        if a.fail_at == Some(call) {
            return None;
        }
        let physical = (call as u64 + 1) * 0x100000;
        a.live.push((physical, count));
        Some(physical)
    })
}
mod memory {
    pub mod phys {
        pub fn r4os_rust_phys_to_virt(p: u64) -> u64 {
            assert_ne!(p, 0);
            p + 0x100000000
        }
        pub fn r4os_rust_phys_free(p: u64) {
            crate::ALLOC.with_borrow_mut(|a| {
                let i = a
                    .live
                    .iter()
                    .position(|v| *v == (p, 1))
                    .expect("exact single frame");
                a.live.remove(i);
            });
        }
    }
}
mod usb {
    pub mod xhci_constants {
        pub const BULK_BUFFER_FRAMES: u16 = 16;
    }
    #[derive(Default)]
    pub struct Current {
        pub interrupt_ring_phys: u64,
        pub interrupt_buffer_phys: u64,
        pub bulk_in_ring_phys: u64,
        pub bulk_out_ring_phys: u64,
        pub bulk_buffer_phys: u64,
        pub bulk_buffer_frames: u16,
    }
    #[derive(Default)]
    pub struct State {
        pub active_runtime_index: Option<usize>,
        pub current: Current,
        pub first_interrupt_ring_virt: u64,
        pub first_interrupt_buffer_virt: u64,
        pub first_bulk_in_ring_virt: u64,
        pub first_bulk_out_ring_virt: u64,
        pub first_bulk_buffer_virt: u64,
        pub interrupt_inits: usize,
        pub bulk_inits: usize,
        pub persists: usize,
    }
    pub mod xhci_state {
        #[derive(Clone, Copy)]
        pub struct Context(pub *mut super::State);
        pub unsafe fn state(c: Context) -> *mut super::State {
            c.0
        }
        pub unsafe fn current(c: Context) -> *mut super::Current {
            unsafe { &raw mut (*c.0).current }
        }
    }
    pub mod xhci_hardware {
        pub fn alloc_frame_zero() -> Option<u64> {
            crate::allocate(1)
        }
        pub fn alloc_contiguous_zero(n: u16) -> Option<u64> {
            crate::allocate(n)
        }
    }
    pub mod xhci_rings {
        pub unsafe fn init_interrupt_ring(c: super::xhci_state::Context) {
            unsafe {
                assert_ne!((*c.0).first_interrupt_ring_virt, 0);
                assert_ne!((*c.0).first_interrupt_buffer_virt, 0);
                (*c.0).interrupt_inits += 1;
            }
        }
        pub unsafe fn init_bulk_rings(c: super::xhci_state::Context) {
            unsafe {
                assert_ne!((*c.0).first_bulk_in_ring_virt, 0);
                assert_ne!((*c.0).first_bulk_out_ring_virt, 0);
                assert_ne!((*c.0).first_bulk_buffer_virt, 0);
                (*c.0).bulk_inits += 1;
            }
        }
    }
    pub mod xhci_runtime {
        use super::xhci_state::{Context, state};
        unsafe fn persist_active_runtime(c: Context) {
            unsafe {
                (*c.0).persists += 1;
            }
        }
        // OWNER_FUNCTIONS
    }
    pub unsafe fn ensure_interrupt_storage(c: xhci_state::Context) -> bool {
        unsafe { xhci_runtime::ensure_interrupt_storage(c) }
    }
    pub unsafe fn ensure_bulk_storage(c: xhci_state::Context) -> bool {
        unsafe { xhci_runtime::ensure_bulk_storage(c) }
    }
}
use usb::{State, ensure_bulk_storage, ensure_interrupt_storage, xhci_state::Context};
fn reset(fail_at: Option<usize>) -> State {
    ALLOC.with_borrow_mut(|a| {
        *a = Allocator {
            fail_at,
            ..Default::default()
        }
    });
    State {
        active_runtime_index: Some(0),
        ..Default::default()
    }
}
#[test]
fn interrupt_failure_at_every_allocation_keeps_group_unpublished() {
    for fail in 0..2 {
        let mut s = reset(Some(fail));
        assert!(!unsafe { ensure_interrupt_storage(Context(&mut s)) });
        ALLOC.with_borrow(|a| assert!(a.live.is_empty()));
        assert_eq!(
            (
                s.current.interrupt_ring_phys,
                s.current.interrupt_buffer_phys
            ),
            (0, 0)
        );
        assert_eq!(
            (s.first_interrupt_ring_virt, s.first_interrupt_buffer_virt),
            (0, 0)
        );
        assert_eq!((s.interrupt_inits, s.persists), (0, 0));
    }
}
#[test]
fn bulk_failure_at_every_allocation_keeps_group_unpublished() {
    for fail in 0..3 {
        let mut s = reset(Some(fail));
        assert!(!unsafe { ensure_bulk_storage(Context(&mut s)) });
        ALLOC.with_borrow(|a| assert!(a.live.is_empty()));
        assert_eq!(
            (
                s.current.bulk_in_ring_phys,
                s.current.bulk_out_ring_phys,
                s.current.bulk_buffer_phys,
                s.current.bulk_buffer_frames
            ),
            (0, 0, 0, 0)
        );
        assert_eq!(
            (
                s.first_bulk_in_ring_virt,
                s.first_bulk_out_ring_virt,
                s.first_bulk_buffer_virt
            ),
            (0, 0, 0)
        );
        assert_eq!((s.bulk_inits, s.persists), (0, 0));
    }
}
#[test]
fn independent_groups_publish_once_and_reuse_without_reinitialization() {
    let mut s = reset(None);
    let c = Context(&mut s);
    assert!(unsafe { ensure_interrupt_storage(c) });
    let interrupt = s.current.interrupt_ring_phys;
    ALLOC.with_borrow(|a| assert_eq!(a.live.len(), 2));
    assert!(unsafe { ensure_bulk_storage(c) });
    for _ in 0..4 {
        assert!(unsafe { ensure_interrupt_storage(c) });
        assert!(unsafe { ensure_bulk_storage(c) });
    }
    assert_eq!(s.current.interrupt_ring_phys, interrupt);
    assert_eq!((s.interrupt_inits, s.bulk_inits, s.persists), (1, 1, 2));
    ALLOC.with_borrow(|a| {
        assert_eq!(a.calls, 5);
        assert_eq!(a.live.iter().map(|v| v.1 as u64).sum::<u64>(), 20);
    });
}
#[test]
fn absent_runtime_and_partial_existing_groups_are_retained() {
    let mut s = reset(None);
    s.active_runtime_index = None;
    let c = Context(&mut s);
    assert!(!unsafe { ensure_interrupt_storage(c) });
    assert!(!unsafe { ensure_bulk_storage(c) });
    s.active_runtime_index = Some(0);
    s.current.interrupt_ring_phys = 0xfeed000;
    s.current.bulk_buffer_phys = 0xbeef000;
    assert!(!unsafe { ensure_interrupt_storage(c) });
    assert!(!unsafe { ensure_bulk_storage(c) });
    assert_eq!(s.current.interrupt_ring_phys, 0xfeed000);
    assert_eq!(s.current.bulk_buffer_phys, 0xbeef000);
    ALLOC.with_borrow(|a| assert_eq!(a.calls, 0));
    assert_eq!(s.persists, 0);
}
