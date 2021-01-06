#![no_std]
#![feature(default_alloc_error_handler)]
#![feature(lang_items)]
#![feature(integer_atomics)]
#![feature(drain_filter)]
#![allow(dead_code)]

extern crate alloc;
use alloc::sync::Arc;
use alloc::vec::Vec;
use core::sync::atomic::{AtomicU32, Ordering};
use core::{cmp::min, ptr::copy_nonoverlapping};
use cstr_core::{c_char, CString};
use heapless::binary_heap::{BinaryHeap, Max};
use heapless::consts::*;
use rand_core::*;
use rand_xorshift::XorShiftRng;
use spin::RwLock;

#[cfg(test)]
#[macro_use]
extern crate std;

#[cfg(test)]
#[allow(unused_imports)]
use std::{collections::HashMap, prelude::*};

#[cfg(not(test))]
use core::panic::PanicInfo;

#[cfg(not(test))]
#[panic_handler]
fn panic(_panic: &PanicInfo<'_>) -> ! {
    loop {}
}

#[cfg(target_arch = "arm")]
use alloc_cortex_m::CortexMHeap;

#[cfg(target_arch = "arm")]
#[global_allocator]
static ALLOCATOR: CortexMHeap = CortexMHeap::empty();

#[cfg(target_arch = "arm")]
#[no_mangle]
pub extern "C" fn qs_init() {
    let start = cortex_m_rt::heap_start() as usize;
    let size = 1024; // in bytes
    unsafe { ALLOCATOR.init(start, size) }

    shared_qs_init();
}

#[cfg(any(target_arch = "aarch64", target_arch = "x86_64"))]
use jemallocator::Jemalloc;

#[cfg(any(target_arch = "aarch64", target_arch = "x86_64"))]
#[global_allocator]
static ALLOCATOR: Jemalloc = Jemalloc;

#[cfg(not(test))]
#[cfg(any(target_arch = "aarch64", target_arch = "x86_64"))]
#[lang = "eh_personality"]
extern "C" fn eh_personality() {}

#[cfg(any(target_arch = "aarch64", target_arch = "x86_64"))]
#[no_mangle]
extern "C" fn rust_oom() {}

#[cfg(any(target_arch = "aarch64", target_arch = "x86_64"))]
#[no_mangle]
pub extern "C" fn qs_init() {
    // nop, use default jemalloc
    shared_qs_init();
}

fn shared_qs_init() {
    // nop right now
}

#[no_mangle]
pub extern "C" fn qs_errors_pop() -> *mut c_char {
    let mut error_guard = ERRORS.write();
    match (*error_guard).pop() {
        Some(message) => {
            return message.into_raw();
        }
        None => {
            return core::ptr::null_mut();
        }
    }
}

#[no_mangle]
pub extern "C" fn qs_errors_drop(cstr: *mut c_char) {
    unsafe {
        if !cstr.is_null() {
            CString::from_raw(cstr);
        }
    }
}

#[no_mangle]
pub extern "C" fn qs_create_measurement(signal_channels: u8) -> u32 {
    let measurement = Measurement::new(signal_channels);
    let id = measurement.id;
    let rwm = RwMeasurement {
        id,
        measurement: Arc::new(RwLock::new(measurement)),
    };
    let mut heap_guard = MEASUREMENTS.write();
    match (*heap_guard).push(rwm) {
        Ok(()) => return id,
        Err(_) => return 0,
    }
}

#[no_mangle]
pub extern "C" fn qs_drop_measurement(measurement_id: u32) {
    let mut heap_guard = MEASUREMENTS.write();
    let mut put_back = Vec::new();
    loop {
        match (*heap_guard).pop() {
            Some(value) => {
                if value.id == measurement_id {
                    break;
                } else {
                    put_back.push(value);
                }
            }
            None => break,
        }
    }
    put_back.into_iter().for_each(|e| {
        let _ = (*heap_guard).push(e);
        ()
    });
}

#[no_mangle]
pub extern "C" fn qs_add_signals(measurement_id: u32, buf: *const u8, len: u16) -> u32 {
    if buf.is_null() {
        return 0;
    }
    let rw_measurement = match find_measurement_by_id(measurement_id) {
        Some(rwm) => rwm,
        None => return 0,
    };
    let mut measurement_guard = rw_measurement.measurement.write();
    let mut owned_buf = [0 as u8; 2048 + 128];
    unsafe {
        copy_nonoverlapping(buf, owned_buf.as_mut_ptr(), len as usize);
    }
    let result = (*measurement_guard).consume(&owned_buf[0..len as usize]);
    match result {
        Ok(num_samples) => num_samples,
        Err(err) => {
            let mut error_guard = ERRORS.write();
            if (*error_guard).len() < 16 {
                (*error_guard).push(CString::new(err).unwrap());
            }
            0
        }
    }
}

#[no_mangle]
pub extern "C" fn qs_interpret_timestamps(
    measurement_id: u32,
    hz: f32,
    rate_scaler: f32,
    downsample_seed: u64,
    downsample_threshold: u32,
    downsample_scale: u32,
    timestamps: *mut f64,
    num_timestamps: *mut u32,
) -> bool {
    let rw_measurement = match find_measurement_by_id(measurement_id) {
        Some(rwm) => rwm,
        None => return false,
    };
    let measurement_guard = rw_measurement.measurement.read();
    let num_samples = unsafe { *num_timestamps };

    let samples_per_payload = (*measurement_guard)
        .payloads
        .iter()
        .map(|p| p.channels[0].len())
        .sum::<usize>() as f64
        / (*measurement_guard).payloads.len() as f64;

    let mut rng = XorShiftRng::seed_from_u64(downsample_seed);
    let time_per_sample = (1.0 * rate_scaler / hz) as f64;
    let time_per_payload = time_per_sample * samples_per_payload; // Assuming 64 per payload
    let mut timestamp_index: u32 = 0;
    let mut timestamp: f64 = 0 as f64;
    let mut prev_payload_counter = None;
    for payload in (*measurement_guard).payloads.iter() {
        match prev_payload_counter {
            Some(prev) => {
                let missed_payloads = payload.counter - prev;
                let missed_payloads = min(missed_payloads - 1, 0) as f64;
                timestamp += missed_payloads * time_per_payload;
            }
            None => (),
        }
        prev_payload_counter = Some(payload.counter);

        let num_samples_in_payload = payload.channels[0].len();
        for _ in 0..num_samples_in_payload {
            unsafe {
                if timestamp_index >= num_samples {
                    // drop the rest of samples, we randomly oversampled
                    *num_timestamps = timestamp_index;
                    return true;
                }
            }

            if rng.next_u32() % downsample_scale <= downsample_threshold {
                unsafe {
                    let buf_ptr = timestamps.offset(timestamp_index as isize);
                    core::ptr::write(buf_ptr, timestamp);
                }
                timestamp_index += 1;
            }
            timestamp += time_per_sample;
        }
    }
    unsafe {
        *num_timestamps = timestamp_index;
    }

    true
}

#[no_mangle]
pub extern "C" fn qs_copy_signals(
    measurement_id: u32,
    downsample_seed: u64,
    downsample_threshold: u32,
    downsample_scale: u32,
    channel_data: *mut *mut f64,
    num_samples_per_channel: *mut u32,
) -> bool {
    let rw_measurement = match find_measurement_by_id(measurement_id) {
        Some(rwm) => rwm,
        None => return false,
    };
    let measurement_guard = rw_measurement.measurement.read();
    let num_samples = unsafe { *num_samples_per_channel };

    let mut rng = XorShiftRng::seed_from_u64(downsample_seed);
    let mut sample_index: u32 = 0;
    for payload in (*measurement_guard).payloads.iter() {
        let num_samples_in_payload = payload.channels[0].len() as u32;
        let mut sample_mask = (0..num_samples_in_payload)
            .map(|_| rng.next_u32() % downsample_scale <= downsample_threshold)
            .collect::<Vec<bool>>();
        let mut downsample_index = 0;
        for v in sample_mask.iter_mut() {
            if *v && downsample_index < num_samples {
                downsample_index += 1;
            } else {
                *v = false;
            }
        }
        for i in 0..payload.active_channels {
            let channel: *mut f64 = unsafe { *channel_data.offset(i as isize) };
            let mut copy_index = 0;
            payload.channels[i as usize]
                .iter()
                .zip(&sample_mask)
                .filter(|v| *v.1)
                .map(|v| v.0)
                .for_each(|v| {
                    unsafe {
                        (*channel.offset(sample_index as isize + copy_index as isize)) = *v as f64;
                    }
                    copy_index += 1
                })
        }
        sample_index += sample_mask.iter().filter(|v| **v).map(|_v| 1).sum::<u32>();
    }
    unsafe {
        *num_samples_per_channel = sample_index;
    }

    true
}

fn find_measurement_by_id(measurement_id: u32) -> Option<RwMeasurement> {
    let heap_guard = MEASUREMENTS.read();
    let top = (*heap_guard).peek();
    let rw_measurement = match top {
        Some(top) => {
            if top.id == measurement_id {
                top
            } else {
                let rwm = (*heap_guard)
                    .iter()
                    .find(|rwm| rwm.id == measurement_id)
                    .into_iter()
                    .next();
                match rwm {
                    Some(rwm) => rwm,
                    None => return None,
                }
            }
        }
        None => return None,
    };
    return Some(rw_measurement.clone());
}

static MEASUREMENT_ID: AtomicU32 = AtomicU32::new(0);
static MEASUREMENTS: RwLock<BinaryHeap<RwMeasurement, U32, Max>> =
    RwLock::new(BinaryHeap(heapless::i::BinaryHeap::new()));
static ERRORS: RwLock<Vec<CString>> = RwLock::new(Vec::new());

#[derive(Default)]
struct Measurement {
    id: u32,
    payloads: Vec<Payload>,
    active_channels: u8,
}

#[derive(Clone)]
struct RwMeasurement {
    id: u32,
    measurement: Arc<RwLock<Measurement>>,
}

impl Ord for RwMeasurement {
    fn cmp(&self, other: &Self) -> core::cmp::Ordering {
        self.id.cmp(&other.id)
    }
}

impl Eq for RwMeasurement {}

impl PartialOrd for RwMeasurement {
    fn partial_cmp(&self, other: &Self) -> Option<core::cmp::Ordering> {
        self.id.partial_cmp(&other.id)
    }
}

impl PartialEq for RwMeasurement {
    fn eq(&self, other: &Self) -> bool {
        self.id.eq(&other.id)
    }
}

impl Measurement {
    pub fn new(active_channels: u8) -> Measurement {
        Measurement {
            id: MEASUREMENT_ID.fetch_add(1, Ordering::SeqCst),
            active_channels,
            ..Default::default()
        }
    }

    pub fn consume(self: &mut Self, data: &[u8]) -> Result<u32, &'static str> {
        let payload = Payload::new(self.active_channels, data)?;
        let new_samples = payload.channels[0].len();

        if let Err(pos) = self.payloads.binary_search(&payload) {
            self.payloads.insert(pos, payload);
        }

        Ok(new_samples as u32)
    }
}

struct Payload {
    counter: u64,
    channels: [Vec<i16>; 8],
    active_channels: u8,
}

impl Ord for Payload {
    fn cmp(&self, other: &Self) -> core::cmp::Ordering {
        self.counter.cmp(&other.counter)
    }
}

impl Eq for Payload {}

impl PartialOrd for Payload {
    fn partial_cmp(&self, other: &Self) -> Option<core::cmp::Ordering> {
        self.counter.partial_cmp(&other.counter)
    }
}

impl PartialEq for Payload {
    fn eq(&self, other: &Self) -> bool {
        self.counter.eq(&other.counter)
    }
}

impl Payload {
    pub fn new(active_channels: u8, data: &[u8]) -> Result<Payload, &'static str> {
        let (counter, channels) = Payload::parse(data)?;
        Ok(Payload {
            counter,
            channels,
            active_channels,
        })
    }

    fn parse(data: &[u8]) -> Result<(u64, [Vec<i16>; 8]), &'static str> {
        let bytes = data[0] as u16 + ((data[1] as u16) << 8);
        if bytes as usize != data.len() {
            return Err("Bytes in payload does not match specified bytes in payload");
        }

        let _reserved = data[2];

        let channels_and_counter_overflow = data[3];
        let channels = ((channels_and_counter_overflow & 0xf0) >> 4) as usize;
        let counter_overflow = channels_and_counter_overflow & 0x0f;
        let counter = core::u32::MAX as u64 * counter_overflow as u64;
        let counter: u64 = counter
            + (((data[4] as u64) << (8 * 0))
                + ((data[5] as u64) << (8 * 1))
                + ((data[6] as u64) << (8 * 2))
                + ((data[7] as u64) << (8 * 3)));

        if channels > 8 {
            return Err("More channels specified in payload than supported");
        }

        if channels == 0 {
            return Err("Specified 0 channels in payload");
        }

        let channel_data_size = (bytes - (2 + 1 + 1 + 4)) as usize;
        if channel_data_size % (channels * 2) != 0 {
            return Err("Not all specified channels present in payload");
        }

        if counter_overflow >= 64 {
            return Err("Likely invalid notification counter overflow");
        }

        let mut channel_signals: [Vec<i16>; 8] = Default::default();
        let mut data_index = 2 + 1 + 1 + 4;
        let mut channel_index = 0;
        while data_index < data.len() {
            channel_signals[channel_index]
                .push((data[data_index] as i16) + ((data[data_index + 1] as i16) << 8));
            channel_index += 1;
            data_index += 2;

            if channel_index % channels == 0 {
                channel_index = 0;

                // Mark new sample (implied time displacement)
            }
        }

        Ok((counter, channel_signals))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use assert_approx_eq::assert_approx_eq;

    fn setup() {
        qs_init();
    }

    #[test]
    fn create_measurement() {
        let _ = Measurement::new(1);
    }

    #[test]
    #[allow(overflowing_literals)]
    fn add_payload_to_measurement() {
        let mut measurement = Measurement::new(3);
        let raw_payload: [u8; 20] = [
            20, 0,          // num bytes as u16
            0,          // reserved
            0b00110000, // num channels as u4, num counter overflow as u4
            1, 0, 0, 0, // num notifications as u32
            // Sample 0 of Notification 1
            0x10, 0x00, // channel 0 sample value as i16
            0xff, 0xff, // channel 1 sample value as i16
            0x00, 0xff, // channel 1 sample value as i16
            // Sample 1 of Notification 1
            0x11, 0x00, // channel 0 sample value as i16
            0x0f, 0xff, // channel 1 sample value as i16
            0x00, 0x0f, // channel 1 sample value as i16
        ];

        assert_eq!(measurement.consume(&raw_payload), Ok(2));
        assert_eq!(measurement.payloads.len(), 1);
        assert_eq!(measurement.active_channels, 3);

        let payload = &measurement.payloads[0];
        assert_eq!(payload.counter, 1);
        assert_eq!(payload.active_channels, 3);
        assert_eq!(payload.channels[0][0], 0x0010 as i16);
        assert_eq!(payload.channels[1][0], 0xffff as i16);
        assert_eq!(payload.channels[2][0], 0xff00 as i16);
        assert_eq!(payload.channels[0][1], 0x0011 as i16);
        assert_eq!(payload.channels[1][1], 0xff0f as i16);
        assert_eq!(payload.channels[2][1], 0x0f00 as i16);
    }

    #[test]
    fn create_and_drop_measurement() {
        setup();

        let measurement_id = qs_create_measurement(2);
        qs_drop_measurement(measurement_id);
        let measurement_id = qs_create_measurement(1);
        qs_drop_measurement(measurement_id);
    }

    #[test]
    #[allow(overflowing_literals)]
    fn create_and_update_measurement() {
        setup();

        // Create a measurement
        let measurement_id = qs_create_measurement(3);

        // Add a payload tested below the FFI interface
        let raw_payload: [u8; 20] = [
            20, 0,          // num bytes as u8
            0,          // reserved
            0b00110000, // num channels as u4, num counter overflow as u4
            1, 0, 0, 0, // num notifications as u32
            // Sample 0 of Notification 1
            0x10, 0x00, // channel 0 sample value as i16
            0xff, 0xff, // channel 1 sample value as i16
            0x00, 0xff, // channel 1 sample value as i16
            // Sample 1 of Notification 1
            0x11, 0x00, // channel 0 sample value as i16
            0x0f, 0xff, // channel 1 sample value as i16
            0x00, 0x0f, // channel 1 sample value as i16
        ];

        let num_samples = qs_add_signals(
            measurement_id,
            raw_payload.as_ptr(),
            raw_payload.len() as u16,
        );
        assert_eq!(num_samples, 2);

        // Get the timeestamps
        let mut num_timestamps: u32 = 2;
        let mut timestamps: [f64; 2] = Default::default();
        let result = qs_interpret_timestamps(
            measurement_id,
            2 as f32,
            4 as f32,
            0xDEADBEEF,
            1,
            1,
            timestamps.as_mut_ptr(),
            &mut num_timestamps,
        );
        assert!(result);
        assert_eq!(num_timestamps, 2);
        assert_approx_eq!(timestamps[0], 0 as f64);
        assert_approx_eq!(timestamps[1], 2 as f64);

        // Get the channel data
        let mut num_samples: u32 = 2;
        let mut channel0_data: [f64; 2] = Default::default();
        let mut channel1_data: [f64; 2] = Default::default();
        let mut channel2_data: [f64; 2] = Default::default();
        let mut channel_data: [*mut f64; 3] = [
            channel0_data.as_mut_ptr(),
            channel1_data.as_mut_ptr(),
            channel2_data.as_mut_ptr(),
        ];
        let result = qs_copy_signals(
            measurement_id,
            0xDEADBEEF,
            1,
            1,
            channel_data.as_mut_ptr(),
            &mut num_samples,
        );
        assert!(result);
        assert_eq!(num_samples, 2);
        assert_approx_eq!(channel0_data[0], 0x0010 as i16 as f64);
        assert_approx_eq!(channel1_data[0], 0xffff as i16 as f64);
        assert_approx_eq!(channel2_data[0], 0xff00 as i16 as f64);
        assert_approx_eq!(channel0_data[1], 0x0011 as i16 as f64);
        assert_approx_eq!(channel1_data[1], 0xff0f as i16 as f64);
        assert_approx_eq!(channel2_data[1], 0x0f00 as i16 as f64);

        // Drop the measurement
        qs_drop_measurement(measurement_id);
    }

    //  Marshal and unmarshal a lot of random signals on various channels
    #[test]
    fn use_measurement_like_real_worl_use_case() {
        setup();

        // Create a measurement
        let signal_channels = 6;
        let measurement_id = qs_create_measurement(signal_channels);

        // Prepare a bunch of payloads
        let samples_per_payload = 20; // 2 + 1 + 1 + 4 + (6 * 2) * 20 = 248
        let payloads: Vec<_> = (0..1000)
            .map(|i: u32| {
                let mut raw_payload: [u8; 248] = [
                    248, 0,          // Full Payload
                    0,          // reserved
                    0b01100000, // 6 Channels
                    0, 0, 0, 0, // Notification counter, set after the fact
                    // 64 bytes to fill randomly
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 64 bytes to fill randomly
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 64 bytes to fill randomly
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 32 bytes to fill randomly
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, // 16 bytes to fill randomly
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                ];

                let payload_ptr: *mut u8 = unsafe { raw_payload.as_mut_ptr().offset(4) };
                let notification_ptr: *const u8 = &i as *const u32 as *const u8;
                unsafe {
                    core::ptr::copy_nonoverlapping(notification_ptr, payload_ptr, 4);
                }

                for i in 8..248 {
                    raw_payload[i] = rand::random();
                }

                raw_payload
            })
            .collect();

        // Add a bunch of payloads
        for i in 0..(payloads.len() / 2) {
            let samples = qs_add_signals(
                measurement_id,
                payloads[i].as_ptr(),
                payloads[i].len() as u16,
            );
            assert_eq!(samples, 20); // this is how many are in each payload
        }

        // Observe the state of the payloads for graphing or export
        match_payloads(
            measurement_id,
            signal_channels,
            samples_per_payload,
            &payloads[0..(payloads.len() / 2)],
            0xFEEDBEEF,
            1,
            1,
        );

        // Continue adding a bunch of payloads
        for i in (payloads.len() / 2)..payloads.len() {
            let samples = qs_add_signals(
                measurement_id,
                payloads[i].as_ptr(),
                payloads[i].len() as u16,
            );
            assert_eq!(samples, 20); // this is how many are in each payload
        }

        // Observe the state of the payloads for export or correctness
        match_payloads(
            measurement_id,
            signal_channels,
            samples_per_payload,
            &payloads[0..],
            0xFEEDBEAF,
            1,
            1,
        );

        // Drop the measurment
        qs_drop_measurement(measurement_id);
    }

    #[test]
    fn use_measurement_like_real_worl_use_case_with_downsampling() {
        setup();

        // Create a measurement
        let signal_channels = 6;
        let measurement_id = qs_create_measurement(signal_channels);

        // Prepare a bunch of payloads
        let samples_per_payload = 20; // 1 + 1 + 4 + (6 * 2) * 20 = 246
        let payloads: Vec<_> = (0..1000)
            .map(|i: u32| {
                let mut raw_payload: [u8; 248] = [
                    248, 0,          // Full Payload
                    0,          // reserved
                    0b01100000, // 6 Channels
                    0, 0, 0, 0, // Notification counter, set after the fact
                    // 64 bytes to fill randomly
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 64 bytes to fill randomly
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 64 bytes to fill randomly
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 32 bytes to fill randomly
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, // 16 bytes to fill randomly
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                ];

                let payload_ptr: *mut u8 = unsafe { raw_payload.as_mut_ptr().offset(4) };
                let notification_ptr: *const u8 = &i as *const u32 as *const u8;
                unsafe {
                    core::ptr::copy_nonoverlapping(notification_ptr, payload_ptr, 4);
                }

                for i in 8..248 {
                    raw_payload[i] = rand::random();
                }

                raw_payload
            })
            .collect();

        // Add a bunch of payloads
        for i in 0..(payloads.len() / 2) {
            let samples = qs_add_signals(
                measurement_id,
                payloads[i].as_ptr(),
                payloads[i].len() as u16,
            );
            assert_eq!(samples, 20); // this is how many are in each payload
        }

        // Observe the state of the payloads for graphing or export
        match_payloads(
            measurement_id,
            signal_channels,
            samples_per_payload,
            &payloads[0..(payloads.len() / 2)],
            0xDEADBEEF,
            1024 * 512,
            1024 * 1024,
        );

        // Continue adding a bunch of payloads
        for i in (payloads.len() / 2)..payloads.len() {
            let samples = qs_add_signals(
                measurement_id,
                payloads[i].as_ptr(),
                payloads[i].len() as u16,
            );
            assert_eq!(samples, 20); // this is how many are in each payload
        }

        // Observe the state of the payloads for export or correctness
        match_payloads(
            measurement_id,
            signal_channels,
            samples_per_payload,
            &payloads[0..],
            0xDEADBEEF,
            1024 * 512,
            1024 * 1024,
        );

        // Drop the measurment
        qs_drop_measurement(measurement_id);
    }

    fn match_payloads(
        measurement_id: u32,
        channels: u8,
        samples_per_payload: usize,
        payloads: &[[u8; 248]],
        downsample_seed: u64,
        downsample_threshold: u32,
        downsample_scale: u32,
    ) {
        // Prepare bufferes for the anticapated results
        let samples = samples_per_payload * payloads.len();
        let mut timestamps: Vec<f64> = Vec::with_capacity(samples);
        let mut channel_data_bufs: Vec<Vec<f64>> = vec![vec![0 as f64; samples]; channels as usize];

        // Create a rng that is the same as the timestamps
        let mut rng = XorShiftRng::seed_from_u64(downsample_seed);
        let generated_mask = (0..samples)
            .map(|_| rng.next_u32() % downsample_scale <= downsample_threshold)
            .collect::<Vec<bool>>();
        let downsampled_samples = generated_mask
            .iter()
            .filter(|v| **v)
            .map(|_| 1 as usize)
            .sum::<usize>();
        let expected_timestamps = (0..samples)
            .map(|i| i * 2)
            .zip(&generated_mask)
            .filter(|v| *v.1)
            .map(|v| v.0 as f64)
            .take(samples) // behavior drops values that won't fit when downsampling
            .collect::<Vec<f64>>();

        // Get the timestamps
        let mut num_timestamps: u32 = downsampled_samples as u32;
        let result = qs_interpret_timestamps(
            measurement_id,
            2 as f32,
            4 as f32,
            downsample_seed,
            downsample_threshold,
            downsample_scale,
            timestamps.as_mut_ptr(),
            &mut num_timestamps,
        );
        assert!(result);
        assert_eq!(num_timestamps, downsampled_samples as u32);
        timestamps
            .iter()
            .zip(expected_timestamps)
            .for_each(|v| assert_approx_eq!(v.0, v.1));

        // Create a rng that is the same as the timestamps
        let mut rng = XorShiftRng::seed_from_u64(downsample_seed);
        let generated_mask = (0..samples)
            .map(|_| rng.next_u32() % downsample_scale <= downsample_threshold)
            .collect::<Vec<bool>>();
        let downsampled_samples = generated_mask
            .iter()
            .filter(|v| **v)
            .map(|_| 1 as usize)
            .sum::<usize>();

        // Get the channel data
        let mut num_samples_per_channel: u32 = downsampled_samples as u32;
        let mut channel_data: [*mut f64; 8] = [core::ptr::null_mut(); 8];
        channel_data_bufs
            .iter_mut()
            .enumerate()
            .for_each(|(i, val)| channel_data[i] = val.as_mut_ptr());
        let result = qs_copy_signals(
            measurement_id,
            downsample_seed,
            downsample_threshold,
            downsample_scale,
            channel_data.as_mut_ptr(),
            &mut num_samples_per_channel,
        );
        assert!(result);
        // assert_eq!(num_samples_per_channel, downsampled_samples as u32);

        let mut assertions = 0 as usize;
        let mut global_sample_index = 0 as usize;
        let mut global_downsample_index = 0 as usize;
        for (_payload_index, payload) in payloads.iter().enumerate() {
            // println!("Payload {}", _payload_index);
            let payload_ptr = payload as *const u8;
            let mut downsampled_index = 0;
            for sample_index in 0..samples_per_payload {
                // println!("Sample {}", sample_index);
                if generated_mask[global_sample_index + sample_index] {
                    // println!("Downsample {}", downsampled_index);
                    for channel_index in 0..channels {
                        unsafe {
                            // packed header
                            let initial_offset = 8;
                            // sizeof(int16) * channels for each sample in the output
                            let one_shot_sample_offset =
                                sample_index as isize * channels as isize * 2 as isize;
                            // sizeof(int16) * each channel already read within the one shot sample
                            let inner_offset = channel_index as isize * 2 as isize;
                            let sample_ptr = payload_ptr
                                .offset(initial_offset + one_shot_sample_offset + inner_offset)
                                as *const i16;
                            let samples = sample_ptr.read();
                            assert_approx_eq!(
                                channel_data_bufs[channel_index as usize]
                                    [global_downsample_index + downsampled_index as usize],
                                samples as f64
                            );
                            assertions += 1;
                        }
                    }
                    downsampled_index += 1;
                }
            }
            global_sample_index += samples_per_payload;
            global_downsample_index += downsampled_index;
        }
        assert_eq!(assertions, downsampled_samples * channels as usize);
    }
}
