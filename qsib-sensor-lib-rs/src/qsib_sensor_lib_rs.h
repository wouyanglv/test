#include <stdint.h>
#include <stdbool.h>

/*!
 * This must be called before using the library.
 * It may be called several times and is thread-safe.
 */
void qs_init();

/*!
 * Routines that result in error conditions may queue
 * error messages to be explored by the user.
 *
 * A library owned C String w/ nul-terminator is returned
 * with the expectation of the user calling the drop function.
 */
const char *qs_errors_pop();
void qs_errors_drop(const char *free_me_please);

/*!
 * Create or drop a measurement that is tracked
 * by the uint32_t id produced during creation. It
 * will remain valid and no other measurements will
 * become associated with the id.
 *
 * Interactions with measurements are threadsafe,
 * spinning on a RwLock that is biased towards readers.
 */
uint32_t qs_create_measurement(uint8_t signal_channels);
bool qs_drop_measurement(uint32_t measurement_id);

/*!
 * Ingests a signal notification from a QSIB sensor
 * with validity checks. Failures are due to invalid
 * payload serialization.
 *
 * Error messages may be popped with the error
 * messaging API with a limit of 16 pending messages.
 *
 * Similarly thread-safe to measurement allocation.
 *
 * @return 0 on failure else number of samples consumed per channel
 */
uint32_t qs_add_signals(uint32_t measurement_id, const uint8_t *buf, uint16_t len);

/*!
 * Using the input sampling rate, we infer using the
 * notification counters and known samples per payload
 * to compute the device side timestamp that is
 * accurate relative to other signals produced by this sensor.
 *
 * Note this does not provide accuracy in delay incurred due to
 * serde or transmission of signals, this information is lost.
 *
 * Error messages may be popped with the error
 * messaging API with a limit of 16 pending messages.
 *
 * Similarly thread-safe to measurement allocation.
 *
 * @param[in] hz          The rate of sampling in Hz (1 second period)
 * @param[in] rate_scaler The multiplier on the Hz period (ie 1 second * rate_scaler)
 * @param[in] downsample_seed The seed for a random number generator used to downsample data
 * @param[in] downsample_threshold The inclusive threshold to accept values after mod downsample_scale
 * @param[in] downsample_scale The mod to map random values into a continuous domain [0, scale]
 * @param[out] timestamps The buffer that will hold the result of interpreting the data
 * @param[in|out] num_timestamps The number of timestamps in the buffer. (Capacity before call, Actual number after)
 *
 * @return success or failure
 */
bool qs_interpret_timestamps(uint32_t measurement_id, float hz, float rate_scaler, uint64_t downsample_seed, uint32_t downsample_threshold, uint32_t downsample_scale, double *timestamps, uint32_t *num_timestamps);

/*!
 * Places each channel's data in continguous buffers and updates the examct number of samples per channel.
 *
 * Error messages may be popped with the error
 * messaging API with a limit of 16 pending messages.
 *
 * Similarly thread-safe to measurement allocation.
 *
 * @param[in] downsample_seed The seed for a random number generator used to downsample data
 * @param[in] downsample_seed The seed for a random number generator used to downsample data
 * @param[in] downsample_threshold The inclusive threshold to accept values after mod downsample_scale
 * @param[in] downsample_scale The mod to map random values into a continuous domain [0, scale]
 * @param[in|out] num_samples_per_channel The number of samples that each channel has in the buffer. (Capacity before call, Actual number after)
 * @param[out] channel_data The 2D matrix of [channel][samples]
 *
 * @return success or failure
 */
bool qs_copy_signals(uint32_t measurement_id, uint64_t downsample_seed, uint32_t downsample_threshold, uint32_t downsample_scale, double **channel_data, uint32_t *num_samples_per_channel);
