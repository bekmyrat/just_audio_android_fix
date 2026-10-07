package com.ryanheise.just_audio;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;

import java.nio.ByteBuffer;
import java.nio.ByteOrder;

/**
 * Downmixes a four-channel "karaoke" source to stereo, applying an independent
 * gain to each of the two stems it carries. A gain change is ramped across one
 * buffer rather than applied as a step, so dragging the slider doesn't click.
 *
 * <p>The source is expected to hold the vocal stem on channels 0/1 and the
 * instrumental stem on channels 2/3 — the layout produced by merging a
 * separated pair with ffmpeg's {@code amerge}:
 *
 * <pre>
 *   out_L = vocalGain * in[0] + instrumentalGain * in[2]
 *   out_R = vocalGain * in[1] + instrumentalGain * in[3]
 * </pre>
 *
 * <p>Both stems living in one file is the whole point: they share a decoder and
 * a clock, so the two halves of the mix stay sample-locked through every seek,
 * pause and track transition without anything having to keep them that way.
 * Two players reading two files cannot offer that — separately encoded files
 * don't even agree on where sample zero is.
 *
 * <p>The processor is inactive for anything that isn't four-channel 16-bit PCM,
 * so ordinary stereo tracks bypass it entirely and pay nothing for it. When
 * {@link #setEnabled} is false a four-channel source is still downmixed — it
 * has to be, the sink wants stereo — but at unity gain on both stems, which
 * reconstructs the full mix.
 */
public class KaraokeMixProcessor implements AudioProcessor {
  /** Channels a source must have before there is a second stem to mix. */
  private static final int REQUIRED_CHANNEL_COUNT = 4;

  private static final int OUTPUT_CHANNEL_COUNT = 2;

  private AudioFormat pendingInputAudioFormat;
  private AudioFormat pendingOutputAudioFormat;
  private AudioFormat inputAudioFormat;
  private AudioFormat outputAudioFormat;

  private ByteBuffer buffer;
  private ByteBuffer outputBuffer;
  private boolean inputEnded;

  // Read from the playback thread on every buffer, written from the platform
  // channel thread whenever the user moves the slider.
  private volatile boolean isEnabled = false;
  private volatile float vocalGain = 1.0f;
  private volatile float instrumentalGain = 1.0f;

  // Whether the configuration in use right now (not one still pending) is a
  // four-channel source being mixed. Written on the playback thread, read
  // from the platform channel thread.
  private volatile boolean mixing = false;

  // The gains the previous buffer ended on, which the next buffer ramps away
  // from. Playback thread only.
  private float appliedVocalGain;
  private float appliedInstrumentalGain;
  private boolean gainsPrimed = false;

  public KaraokeMixProcessor() {
    buffer = EMPTY_BUFFER;
    outputBuffer = EMPTY_BUFFER;
    pendingInputAudioFormat = AudioFormat.NOT_SET;
    pendingOutputAudioFormat = AudioFormat.NOT_SET;
    inputAudioFormat = AudioFormat.NOT_SET;
    outputAudioFormat = AudioFormat.NOT_SET;
  }

  /**
   * Whether the user's gains apply. When false both stems play at unity, which
   * is the original mix.
   */
  public void setEnabled(boolean enabled) {
    this.isEnabled = enabled;
  }

  public boolean isEnabled() {
    return isEnabled;
  }

  /** Both in [0, 1]; anything outside is clamped. */
  public void setGains(float vocalGain, float instrumentalGain) {
    this.vocalGain = clampGain(vocalGain);
    this.instrumentalGain = clampGain(instrumentalGain);
  }

  private static float clampGain(float gain) {
    if (gain < 0.0f) return 0.0f;
    if (gain > 1.0f) return 1.0f;
    return gain;
  }

  /**
   * Whether the source being processed right now actually carries two stems.
   * Lets the player report back whether karaoke is doing anything, rather than
   * leaving the app to guess from silence.
   *
   * <p>Reads the configuration in use, not {@link #isActive}: during a gapless
   * transition the next track's format is configured while the current one is
   * still playing, and that would answer for the wrong track.
   */
  public boolean hasKaraokeSource() {
    return mixing;
  }

  @Override public AudioFormat configure(AudioFormat inputAudioFormat)
          throws UnhandledAudioFormatException {
    pendingInputAudioFormat = inputAudioFormat;
    // Anything that isn't a four-channel 16-bit stream has no second stem to
    // mix, so stay out of the pipeline rather than failing playback. In
    // particular this is the path every ordinary stereo track in the queue
    // takes.
    if (inputAudioFormat.encoding != C.ENCODING_PCM_16BIT
            || inputAudioFormat.channelCount < REQUIRED_CHANNEL_COUNT) {
      pendingOutputAudioFormat = AudioFormat.NOT_SET;
    } else {
      pendingOutputAudioFormat = new AudioFormat(
              inputAudioFormat.sampleRate, OUTPUT_CHANNEL_COUNT, C.ENCODING_PCM_16BIT);
    }
    return pendingOutputAudioFormat;
  }

  @Override public boolean isActive() {
    return !pendingOutputAudioFormat.equals(AudioFormat.NOT_SET);
  }

  @Override public void queueInput(ByteBuffer inputBuffer) {
    int remaining = inputBuffer.remaining();
    if (remaining == 0) {
      return;
    }

    int inputChannelCount = inputAudioFormat.channelCount;
    int inputFrameSize = inputChannelCount * 2; // 16-bit samples
    int frames = remaining / inputFrameSize;
    if (frames == 0) {
      return;
    }

    // Disabled means "play it as it was mixed", not "mute a stem".
    boolean enabled = isEnabled;
    float targetVocal = enabled ? vocalGain : 1.0f;
    float targetInstrumental = enabled ? instrumentalGain : 1.0f;

    // Step the gains from where the last buffer left them to the new target
    // over this buffer. Jumping straight there makes every slider movement an
    // audible click on a loud vocal.
    if (!gainsPrimed) {
      appliedVocalGain = targetVocal;
      appliedInstrumentalGain = targetInstrumental;
      gainsPrimed = true;
    }
    float vocal = appliedVocalGain;
    float instrumental = appliedInstrumentalGain;
    float vocalStep = (targetVocal - vocal) / frames;
    float instrumentalStep = (targetInstrumental - instrumental) / frames;

    ByteBuffer buffer = replaceOutputBuffer(frames * OUTPUT_CHANNEL_COUNT * 2);
    int position = inputBuffer.position();

    for (int frame = 0; frame < frames; frame++) {
      vocal += vocalStep;
      instrumental += instrumentalStep;
      int base = position + frame * inputFrameSize;
      short vocalL = inputBuffer.getShort(base);
      short vocalR = inputBuffer.getShort(base + 2);
      short instrumentalL = inputBuffer.getShort(base + 4);
      short instrumentalR = inputBuffer.getShort(base + 6);

      buffer.putShort(mix(vocalL, vocal, instrumentalL, instrumental));
      buffer.putShort(mix(vocalR, vocal, instrumentalR, instrumental));
    }

    // Exactly the target, not the accumulated ramp, so rounding never drifts.
    appliedVocalGain = targetVocal;
    appliedInstrumentalGain = targetInstrumental;

    // Channels beyond the two stems (if the file ever carries any) are dropped.
    inputBuffer.position(position + frames * inputFrameSize);
    buffer.flip();
  }

  /**
   * Sums the two stems and clamps. The stems come from separating one master,
   * so at unity they sum back to roughly that master and the clamp is inert;
   * it only earns its keep on sources whose separation overshoots.
   */
  private static short mix(short vocal, float vocalGain,
                           short instrumental, float instrumentalGain) {
    int mixed = Math.round(vocal * vocalGain + instrumental * instrumentalGain);
    if (mixed > Short.MAX_VALUE) return Short.MAX_VALUE;
    if (mixed < Short.MIN_VALUE) return Short.MIN_VALUE;
    return (short) mixed;
  }

  @Override public void queueEndOfStream() {
    inputEnded = true;
  }

  @Override public ByteBuffer getOutput() {
    ByteBuffer outputBuffer = this.outputBuffer;
    this.outputBuffer = EMPTY_BUFFER;
    return outputBuffer;
  }

  @SuppressWarnings("ReferenceEquality")
  @Override public boolean isEnded() {
    return inputEnded && outputBuffer == EMPTY_BUFFER;
  }

  @Override public void flush() {
    outputBuffer = EMPTY_BUFFER;
    inputEnded = false;
    inputAudioFormat = pendingInputAudioFormat;
    outputAudioFormat = pendingOutputAudioFormat;
    mixing = !outputAudioFormat.equals(AudioFormat.NOT_SET);
    // After a seek or a new track, start on the current gains instead of
    // ramping from wherever the old position left off.
    gainsPrimed = false;
  }

  @Override public void reset() {
    flush();
    buffer = EMPTY_BUFFER;
    pendingInputAudioFormat = AudioFormat.NOT_SET;
    pendingOutputAudioFormat = AudioFormat.NOT_SET;
    inputAudioFormat = AudioFormat.NOT_SET;
    outputAudioFormat = AudioFormat.NOT_SET;
    mixing = false;
  }

  private ByteBuffer replaceOutputBuffer(int size) {
    if (buffer.capacity() < size) {
      buffer = ByteBuffer.allocateDirect(size).order(ByteOrder.nativeOrder());
    } else {
      buffer.clear();
    }
    outputBuffer = buffer;
    return buffer;
  }
}
