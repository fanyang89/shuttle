//! C ABI for single-process test executables. See include/shuttle.h for the caller contract.
use shuttle::future::batch_semaphore::{BatchSemaphore, Fairness};
use shuttle::scheduler::{RandomScheduler, ReplayScheduler};
use shuttle::sync::atomic::{AtomicU32, Ordering::SeqCst};
use shuttle::{thread, Config, MaxSteps, Runner};
use std::ffi::{c_char, c_void, CStr};

type Callback = extern "C" fn(*mut c_void) -> *const c_char;

fn invoke(f: Callback, ctx: usize) {
    let err = f(ctx as *mut c_void);
    if !err.is_null() {
        // The Zig callback has returned; the name has static storage.
        panic!(
            "Zig scenario failed: {}",
            unsafe { CStr::from_ptr(err) }.to_string_lossy()
        );
    }
}

#[no_mangle]
unsafe extern "C" fn shuttle_run(
    f: Callback,
    iterations: usize,
    seed: *const u64,
    replay: *const c_char,
    steps: usize,
) {
    if !cfg!(panic = "abort") {
        panic!("build shuttle-ffi with --profile zig-test");
    }
    assert!(iterations > 0 && steps > 0);
    let mut config = Config::default();
    config.max_steps = MaxSteps::FailAfter(steps);
    let scenario = move || invoke(f, 0);
    if replay.is_null() {
        let scheduler = match seed.as_ref() {
            Some(&s) => RandomScheduler::new_from_seed(s, iterations),
            None => RandomScheduler::new(iterations),
        };
        Runner::new(scheduler, config).run(scenario);
    } else {
        let replay = CStr::from_ptr(replay).to_str().expect("schedule must be UTF-8");
        Runner::new(ReplayScheduler::new_from_encoded(replay), config).run(scenario);
    }
}

#[no_mangle]
extern "C" fn shuttle_spawn(f: Callback, ctx: *mut c_void) -> *mut thread::JoinHandle<()> {
    let ctx = ctx as usize;
    Box::into_raw(Box::new(thread::spawn(move || invoke(f, ctx))))
}

#[no_mangle]
unsafe extern "C" fn shuttle_join(task: *mut thread::JoinHandle<()>) {
    Box::from_raw(task).join().unwrap();
}

#[no_mangle]
unsafe extern "C" fn shuttle_detach(task: *mut thread::JoinHandle<()>) {
    drop(Box::from_raw(task));
}

#[no_mangle]
extern "C" fn shuttle_yield() {
    thread::yield_now();
}

#[no_mangle]
extern "C" fn shuttle_mutex_new() -> *mut BatchSemaphore {
    Box::into_raw(Box::new(BatchSemaphore::new(1, Fairness::Unfair)))
}

#[no_mangle]
unsafe extern "C" fn shuttle_mutex_free(lock: *mut BatchSemaphore) {
    drop(Box::from_raw(lock));
}

#[no_mangle]
extern "C" fn shuttle_mutex_lock(lock: &BatchSemaphore) {
    lock.acquire_blocking(1).unwrap();
}

#[no_mangle]
extern "C" fn shuttle_mutex_try(lock: &BatchSemaphore) -> bool {
    lock.try_acquire(1).is_ok()
}

#[no_mangle]
extern "C" fn shuttle_mutex_unlock(lock: &BatchSemaphore) {
    lock.release(1);
}

#[no_mangle]
extern "C" fn shuttle_u32_new(value: u32) -> *mut AtomicU32 {
    Box::into_raw(Box::new(AtomicU32::new(value)))
}

#[no_mangle]
unsafe extern "C" fn shuttle_u32_free(a: *mut AtomicU32) {
    drop(Box::from_raw(a));
}

#[no_mangle]
extern "C" fn shuttle_u32_load(a: &AtomicU32) -> u32 {
    a.load(SeqCst)
}

#[no_mangle]
extern "C" fn shuttle_u32_store(a: &AtomicU32, v: u32) {
    a.store(v, SeqCst);
}

#[no_mangle]
extern "C" fn shuttle_u32_swap(a: &AtomicU32, v: u32) -> u32 {
    a.swap(v, SeqCst)
}

#[no_mangle]
extern "C" fn shuttle_u32_add(a: &AtomicU32, v: u32) -> u32 {
    a.fetch_add(v, SeqCst)
}

#[no_mangle]
extern "C" fn shuttle_u32_cas(a: &AtomicU32, old: u32, new: u32) -> u32 {
    a.compare_exchange(old, new, SeqCst, SeqCst)
        .unwrap_or_else(|actual| actual)
}
