class_name AudioManager
extends Node
## Procedural 16-bit PCM audio synthesizer and sound controller.
## Provides:
## - Looping synthwave/electronic arena background music while rounds are played
## - High-energy sci-fi laser shooting sound effect when the 5s countdown fires
## - Heavy descending rumble & cascading tile drop sound when outer platform sections drop
## - Tactical countdown ticks and elimination impact effects

const SAMPLE_RATE: int = 22050

var master_volume: float = 1.00
var music_volume: float = 0.80
var sfx_volume: float = 0.90
var sound_muted: bool = false
var _is_ducked: bool = false

var _bgm_player: AudioStreamPlayer
var _laser_player: AudioStreamPlayer
var _drop_player: AudioStreamPlayer
var _warning_player: AudioStreamPlayer
var _tick_player: AudioStreamPlayer
var _elim_player: AudioStreamPlayer

var _bgm_stream: AudioStreamWAV
var _laser_stream: AudioStreamWAV
var _drop_stream: AudioStreamWAV
var _warning_stream: AudioStreamWAV
var _tick_stream: AudioStreamWAV
var _elim_stream: AudioStreamWAV


func _ready() -> void:
	_generate_all_streams()
	_setup_players()
	_apply_volumes()


func start_background_music() -> void:
	if not _bgm_player:
		return
	_is_ducked = false
	_apply_volumes()
	if not _bgm_player.playing:
		_bgm_player.play()


func stop_background_music() -> void:
	if _bgm_player and _bgm_player.playing:
		_bgm_player.stop()


func set_music_ducked(ducked: bool) -> void:
	_is_ducked = ducked
	_apply_volumes()


func set_master_volume(linear_val: float) -> void:
	master_volume = clampf(linear_val, 0.0, 1.0)
	_apply_volumes()


func set_music_volume(linear_val: float) -> void:
	music_volume = clampf(linear_val, 0.0, 1.0)
	_apply_volumes()


func set_sfx_volume(linear_val: float) -> void:
	sfx_volume = clampf(linear_val, 0.0, 1.0)
	_apply_volumes()


func set_sound_muted(muted: bool) -> void:
	sound_muted = muted
	_apply_volumes()


func _apply_volumes() -> void:
	var eff_music := 0.0 if sound_muted else (master_volume * music_volume * (0.38 if _is_ducked else 1.0))
	var eff_sfx := 0.0 if sound_muted else (master_volume * sfx_volume)

	var music_db := -80.0 if eff_music <= 0.001 else linear_to_db(eff_music) - 4.0
	var sfx_db := -80.0 if eff_sfx <= 0.001 else linear_to_db(eff_sfx)

	if _bgm_player:
		_bgm_player.volume_db = music_db
	if _laser_player:
		_laser_player.volume_db = sfx_db - 1.5
	if _drop_player:
		_drop_player.volume_db = sfx_db - 1.0
	if _warning_player:
		_warning_player.volume_db = sfx_db - 4.0
	if _tick_player:
		_tick_player.volume_db = sfx_db - 6.0
	if _elim_player:
		_elim_player.volume_db = sfx_db - 2.0


func play_laser_shoot() -> void:
	if _laser_player:
		_laser_player.pitch_scale = randf_range(0.96, 1.05)
		_laser_player.play()


func play_platform_drop() -> void:
	if _drop_player:
		_drop_player.pitch_scale = randf_range(0.95, 1.04)
		_drop_player.play()


func play_shrink_warning() -> void:
	if _warning_player:
		_warning_player.play()


func play_countdown_tick(final_second: bool = false) -> void:
	if _tick_player:
		_tick_player.pitch_scale = 1.35 if final_second else 1.0
		_tick_player.play()


func play_elimination_sfx() -> void:
	if _elim_player:
		_elim_player.pitch_scale = randf_range(0.94, 1.06)
		_elim_player.play()


func _setup_players() -> void:
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.name = "BGMPlayer"
	_bgm_player.stream = _bgm_stream
	_bgm_player.volume_db = -5.5
	add_child(_bgm_player)

	_laser_player = AudioStreamPlayer.new()
	_laser_player.name = "LaserSFXPlayer"
	_laser_player.stream = _laser_stream
	_laser_player.volume_db = -1.5
	add_child(_laser_player)

	_drop_player = AudioStreamPlayer.new()
	_drop_player.name = "PlatformDropSFXPlayer"
	_drop_player.stream = _drop_stream
	_drop_player.volume_db = -1.0
	add_child(_drop_player)

	_warning_player = AudioStreamPlayer.new()
	_warning_player.name = "WarningSFXPlayer"
	_warning_player.stream = _warning_stream
	_warning_player.volume_db = -4.0
	add_child(_warning_player)

	_tick_player = AudioStreamPlayer.new()
	_tick_player.name = "TickSFXPlayer"
	_tick_player.stream = _tick_stream
	_tick_player.volume_db = -6.0
	add_child(_tick_player)

	_elim_player = AudioStreamPlayer.new()
	_elim_player.name = "EliminationSFXPlayer"
	_elim_player.stream = _elim_stream
	_elim_player.volume_db = -2.0
	add_child(_elim_player)


func _generate_all_streams() -> void:
	_bgm_stream = _build_bgm_stream()
	_laser_stream = _build_laser_stream()
	_drop_stream = _build_platform_drop_stream()
	_warning_stream = _build_warning_stream()
	_tick_stream = _build_tick_stream()
	_elim_stream = _build_elimination_stream()


func _build_bgm_stream() -> AudioStreamWAV:
	# 8-second seamless 120 BPM cyber-arena electronic loop (16 beats, 32 eighth-notes)
	var duration := 8.0
	var total_samples := int(duration * SAMPLE_RATE)
	var pcm := PackedByteArray()
	pcm.resize(total_samples * 2)

	# Bassline MIDI-like frequencies (D minor progression: Dm | Bb | Gm | A)
	var bass_freqs := PackedFloat32Array([
		73.42, 73.42, 146.83, 73.42, 73.42, 73.42, 130.81, 146.83,
		58.27, 58.27, 116.54, 58.27, 58.27, 58.27, 116.54, 130.81,
		98.00, 98.00, 196.00, 98.00, 98.00, 98.00, 174.61, 146.83,
		110.00, 110.00, 220.00, 110.00, 110.00, 130.81, 138.59, 164.81
	])

	# Arpeggio lead notes (32 sixteenth/eighth steps)
	var arp_freqs := PackedFloat32Array([
		293.66, 349.23, 440.00, 587.33, 440.00, 349.23, 523.25, 440.00,
		293.66, 349.23, 466.16, 587.33, 466.16, 349.23, 523.25, 466.16,
		293.66, 392.00, 466.16, 587.33, 523.25, 466.16, 392.00, 349.23,
		277.18, 329.63, 440.00, 554.37, 659.25, 554.37, 440.00, 329.63
	])

	var bass_phase := 0.0
	var arp_phase := 0.0
	var pad_phase_1 := 0.0
	var pad_phase_2 := 0.0
	var noise_seed := 1337

	for i in range(total_samples):
		var t := float(i) / float(SAMPLE_RATE)
		var beat_f := t * 2.0 # 120 BPM = 2 beats per second
		var step_8th := int(t * 4.0) % 32
		var step_pos := fmod(t * 4.0, 1.0) # 0..1 within current eighth note
		var beat_pos := fmod(beat_f, 1.0)  # 0..1 within current quarter-note beat

		# 1. Kick drum on every quarter note beat
		var kick_env := exp(-beat_pos * 18.0)
		var kick_freq := 44.0 + 115.0 * exp(-beat_pos * 34.0)
		var kick := sin(beat_pos * kick_freq * TAU) * kick_env * 0.42

		# 2. Hi-hat / Snare on off-beats and beats 2 & 4
		noise_seed = (noise_seed * 1103515245 + 12345) & 0x7fffffff
		var white := (float(noise_seed % 65536) / 32768.0) - 1.0
		var is_snare_beat := (int(beat_f) % 2) == 1
		var snare := 0.0
		if is_snare_beat:
			snare = white * exp(-beat_pos * 22.0) * 0.20
		var hat_pos := fmod(t * 8.0, 1.0)
		var hat := white * exp(-hat_pos * 45.0) * 0.07

		# 3. Synth Bass
		var b_freq := bass_freqs[step_8th]
		bass_phase = fmod(bass_phase + b_freq / float(SAMPLE_RATE), 1.0)
		var b_env := exp(-step_pos * 4.2)
		# Rich saw + sub sine
		var b_saw := (bass_phase * 2.0 - 1.0) * 0.55 + sin(bass_phase * TAU) * 0.65
		var bass := b_saw * b_env * 0.26

		# 4. Arpeggio Pluck Lead
		var a_freq := arp_freqs[step_8th]
		arp_phase = fmod(arp_phase + a_freq / float(SAMPLE_RATE), 1.0)
		var a_env := exp(-step_pos * 6.5)
		var arp := (sin(arp_phase * TAU) + 0.4 * sin(arp_phase * TAU * 2.0)) * a_env * 0.16

		# 5. Atmospheric Pad (D4 + A4 fifth interval)
		pad_phase_1 = fmod(pad_phase_1 + 293.66 / float(SAMPLE_RATE), 1.0)
		pad_phase_2 = fmod(pad_phase_2 + 440.00 / float(SAMPLE_RATE), 1.0)
		var pad := (sin(pad_phase_1 * TAU) + sin(pad_phase_2 * TAU)) * 0.065

		var mix := clampf(kick + snare + hat + bass + arp + pad, -0.95, 0.95)
		var sample_i16 := int(mix * 32767.0)
		pcm.encode_s16(i * 2, sample_i16)

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = total_samples
	wav.data = pcm
	return wav


func _build_laser_stream() -> AudioStreamWAV:
	# 0.58s punchy sci-fi laser beam discharge sound effect
	var duration := 0.58
	var total_samples := int(duration * SAMPLE_RATE)
	var pcm := PackedByteArray()
	pcm.resize(total_samples * 2)

	var phase := 0.0
	var sub_phase := 0.0
	var noise_seed := 9001

	for i in range(total_samples):
		var t := float(i) / float(SAMPLE_RATE)
		# Rapid downward pitch sweep (2200 Hz -> 190 Hz) with FM modulation
		var sweep_freq := 185.0 + 2100.0 * exp(-t * 19.0)
		var fm := sin(t * 95.0 * TAU) * 140.0 * exp(-t * 8.0)
		phase = fmod(phase + (sweep_freq + fm) / float(SAMPLE_RATE), 1.0)

		# Sub-bass plasma punch (130 Hz -> 38 Hz)
		var sub_freq := 38.0 + 95.0 * exp(-t * 14.0)
		sub_phase = fmod(sub_phase + sub_freq / float(SAMPLE_RATE), 1.0)

		noise_seed = (noise_seed * 1103515245 + 12345) & 0x7fffffff
		var noise := (float(noise_seed % 65536) / 32768.0) - 1.0

		var env := exp(-t * 5.2)
		var snap_env := exp(-t * 36.0)

		var beam_wave := sin(phase * TAU) * 0.55 + (phase * 2.0 - 1.0) * 0.35
		var sub_wave := sin(sub_phase * TAU) * 0.48
		var sizzle := noise * snap_env * 0.35 + noise * env * 0.10

		var mix := clampf((beam_wave * env) + (sub_wave * env) + sizzle, -0.98, 0.98)
		pcm.encode_s16(i * 2, int(mix * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = pcm
	return wav


func _build_platform_drop_stream() -> AudioStreamWAV:
	# 1.25s sound for outer platform / background tiles detaching and dropping into the abyss
	var duration := 1.25
	var total_samples := int(duration * SAMPLE_RATE)
	var pcm := PackedByteArray()
	pcm.resize(total_samples * 2)

	var drop_phase := 0.0
	var rumble_phase := 0.0
	var lp_noise := 0.0
	var noise_seed := 4242

	for i in range(total_samples):
		var t := float(i) / float(SAMPLE_RATE)

		# Descending gravity drop pitch (165 Hz down to 28 Hz)
		var drop_freq := 28.0 + 137.0 * exp(-t * 2.8)
		drop_phase = fmod(drop_phase + drop_freq / float(SAMPLE_RATE), 1.0)
		rumble_phase = fmod(rumble_phase + (drop_freq * 0.52) / float(SAMPLE_RATE), 1.0)

		noise_seed = (noise_seed * 1103515245 + 12345) & 0x7fffffff
		var raw_noise := (float(noise_seed % 65536) / 32768.0) - 1.0
		# Low-pass filter the noise for heavy stone/metal tile collapse rumble
		lp_noise = lp_noise * 0.86 + raw_noise * 0.14

		# Staggered tile detachment clanks at t=0.0, 0.09, 0.19, 0.31s
		var clank_env := (
			exp(-t * 28.0)
			+ 0.75 * exp(-maxf(0.0, t - 0.09) * 32.0) * (1.0 if t >= 0.09 else 0.0)
			+ 0.55 * exp(-maxf(0.0, t - 0.19) * 32.0) * (1.0 if t >= 0.19 else 0.0)
			+ 0.40 * exp(-maxf(0.0, t - 0.31) * 32.0) * (1.0 if t >= 0.31 else 0.0)
		)

		var main_env := clampf(1.0 - (t / duration), 0.0, 1.0)
		var body := sin(drop_phase * TAU) * 0.52 + sin(rumble_phase * TAU) * 0.38
		var clanks := sin(t * 420.0 * TAU) * clank_env * 0.25 + lp_noise * (main_env * 0.55 + clank_env * 0.35)

		var mix := clampf(body * main_env + clanks, -0.98, 0.98)
		pcm.encode_s16(i * 2, int(mix * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = pcm
	return wav


func _build_warning_stream() -> AudioStreamWAV:
	# 0.42s double-pulse danger boundary alarm beep
	var duration := 0.42
	var total_samples := int(duration * SAMPLE_RATE)
	var pcm := PackedByteArray()
	pcm.resize(total_samples * 2)

	var phase := 0.0
	for i in range(total_samples):
		var t := float(i) / float(SAMPLE_RATE)
		var is_second := t > 0.21
		var local_t := (t - 0.21) if is_second else t
		var freq := 880.0 if is_second else 660.0
		phase = fmod(phase + freq / float(SAMPLE_RATE), 1.0)
		var env := exp(-local_t * 14.0)
		var wave := (sin(phase * TAU) + 0.35 * sin(phase * TAU * 3.0)) * env * 0.45
		pcm.encode_s16(i * 2, int(clampf(wave, -0.95, 0.95) * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = pcm
	return wav


func _build_tick_stream() -> AudioStreamWAV:
	# 0.09s crisp countdown tick
	var duration := 0.09
	var total_samples := int(duration * SAMPLE_RATE)
	var pcm := PackedByteArray()
	pcm.resize(total_samples * 2)

	for i in range(total_samples):
		var t := float(i) / float(SAMPLE_RATE)
		var env := exp(-t * 48.0)
		var wave := sin(t * 1046.5 * TAU) * env * 0.45
		pcm.encode_s16(i * 2, int(clampf(wave, -0.95, 0.95) * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = pcm
	return wav


func _build_elimination_stream() -> AudioStreamWAV:
	# 0.48s energetic shatter/explosion burst when a character is eliminated
	var duration := 0.48
	var total_samples := int(duration * SAMPLE_RATE)
	var pcm := PackedByteArray()
	pcm.resize(total_samples * 2)

	var noise_seed := 7777
	var lp := 0.0
	for i in range(total_samples):
		var t := float(i) / float(SAMPLE_RATE)
		noise_seed = (noise_seed * 1103515245 + 12345) & 0x7fffffff
		var noise := (float(noise_seed % 65536) / 32768.0) - 1.0
		lp = lp * 0.78 + noise * 0.22
		var env := exp(-t * 7.5)
		var boom := sin(t * (95.0 * exp(-t * 8.0)) * TAU) * env * 0.55
		var mix := clampf(boom + lp * env * 0.55, -0.98, 0.98)
		pcm.encode_s16(i * 2, int(mix * 32767.0))

	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = SAMPLE_RATE
	wav.stereo = false
	wav.data = pcm
	return wav
