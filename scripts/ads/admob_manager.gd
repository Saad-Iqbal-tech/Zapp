class_name AdMobManager
extends Node
## Google AdMob Integration Manager (via Poing Studios Godot AdMob Plugin v5.1.0 for Godot 4.7.2).
## - Configures the project's Android App ID and Interstitial Ad Unit ID via ProjectSettings.
## - Forces Google's official test interstitial Ad Unit ID during development/debug builds
##   so live ads are never requested during development testing.
## - Preloads and displays interstitial ads ONLY at safe post-match breaks (after the match
##   result screen and before the next match or main menu transition).
## - Never shows an interstitial during active gameplay, countdown, aiming, shooting,
##   matchmaking, lobby joining, or room creation.
## - Guarantees that initialization failures, load failures, show failures, or desktop execution
##   never crash or block the player from continuing normally.

signal admob_initialized(is_native_android: bool)
signal interstitial_loaded(ad_unit_id: String)
signal interstitial_failed_to_load(error_message: String)
signal interstitial_shown(ad_unit_id: String)
signal interstitial_dismissed()
signal interstitial_failed_to_show(error_message: String)
signal interstitial_skipped(reason: String)

const CONFIGURED_APP_ID: String = "ca-app-pub-2206945025056752~4220096311"
const CONFIGURED_INTERSTITIAL_AD_UNIT_ID: String = "ca-app-pub-2206945025056752/7728096486"
const GOOGLE_TEST_INTERSTITIAL_AD_UNIT_ID: String = "ca-app-pub-3940256099942544/1033173712"

const SETTING_ANDROID_ENABLED: String = "admob/general/android/enabled"
const SETTING_ANDROID_APP_ID: String = "admob/general/android/app_id"
# Custom settings live outside "admob/*" because the plugin's editor code prunes unknown admob/* keys.
const SETTING_ADS_ENABLED: String = "zapp_ads/enabled"
const SETTING_INTERSTITIAL_UNIT_ID: String = "zapp_ads/interstitial_ad_unit_id"
const SETTING_TEST_INTERSTITIAL_UNIT_ID: String = "zapp_ads/test_interstitial_ad_unit_id"
const SETTING_USE_TEST_ADS: String = "zapp_ads/use_test_ads"

## Master toggle for ads (set false in project.godot or via setting to bypass native ad SDK for diagnostics).
@export var ads_enabled: bool = true
## Always true during development/debug builds so live ads are never requested while testing.
@export var use_test_ads: bool = true
## Minimum seconds between two interstitials (frequency cap so players are not spammed).
@export var min_interval_sec: float = 75.0

var _last_shown_ms: int = -1

var is_initialized: bool = false
var is_loading_interstitial: bool = false
var is_showing_interstitial: bool = false
var last_error_message: String = ""
var ads_shown_count: int = 0
var ads_shown_during_gameplay_count: int = 0
var unsafe_show_attempts_blocked: int = 0

var _interstitial_ad: InterstitialAd = null
var _interstitial_loader: InterstitialAdLoader = null
var _load_callback: InterstitialAdLoadCallback = null
var _content_callback: FullScreenContentCallback = null
var _pending_continuation: Callable = Callable()

# Simulation state for desktop / automated headless verification without requiring an Android device
var _simulation_enabled: bool = false
var _simulate_load_success: bool = true
var _simulated_ad_ready: bool = false
var _simulate_auto_dismiss_sec: float = 0.05


func _ready() -> void:
	if ProjectSettings.has_setting(SETTING_ADS_ENABLED):
		ads_enabled = bool(ProjectSettings.get_setting(SETTING_ADS_ENABLED, true))
	if ProjectSettings.has_setting(SETTING_USE_TEST_ADS):
		use_test_ads = bool(ProjectSettings.get_setting(SETTING_USE_TEST_ADS, true))
	# Force test ads in debug/development builds so live ads are never requested in development
	if OS.is_debug_build() or OS.has_feature("editor"):
		use_test_ads = true
	initialize_admob()


func get_configured_app_id() -> String:
	return str(ProjectSettings.get_setting(SETTING_ANDROID_APP_ID, CONFIGURED_APP_ID)).strip_edges()


func get_production_interstitial_unit_id() -> String:
	return str(ProjectSettings.get_setting(SETTING_INTERSTITIAL_UNIT_ID, CONFIGURED_INTERSTITIAL_AD_UNIT_ID)).strip_edges()


func get_test_interstitial_unit_id() -> String:
	return str(ProjectSettings.get_setting(SETTING_TEST_INTERSTITIAL_UNIT_ID, GOOGLE_TEST_INTERSTITIAL_AD_UNIT_ID)).strip_edges()


func get_active_interstitial_unit_id() -> String:
	if use_test_ads or OS.is_debug_build() or OS.has_feature("editor"):
		return get_test_interstitial_unit_id()
	return get_production_interstitial_unit_id()


func has_native_android_admob() -> bool:
	if not ads_enabled:
		return false
	return OS.get_name() == "Android" and Engine.has_singleton("PoingGodotAdMob") and Engine.has_singleton("PoingGodotAdMobInterstitialAd")


func is_interstitial_loaded() -> bool:
	if _simulation_enabled:
		return _simulated_ad_ready
	return _interstitial_ad != null


func enable_test_simulation(simulate_load_success: bool = true, auto_dismiss_sec: float = 0.04) -> void:
	_simulation_enabled = true
	_simulate_load_success = simulate_load_success
	_simulate_auto_dismiss_sec = maxf(0.01, auto_dismiss_sec)
	_simulated_ad_ready = false
	is_initialized = true


func disable_test_simulation() -> void:
	_simulation_enabled = false
	_simulated_ad_ready = false


func initialize_admob() -> void:
	if is_initialized:
		return

	if not has_native_android_admob():
		# Desktop, disabled, or non-plugin build: keep game working normally without requiring Android singletons
		is_initialized = true
		admob_initialized.emit(false)
		return

	_load_callback = InterstitialAdLoadCallback.new()
	_load_callback.on_ad_loaded = _on_native_interstitial_loaded
	_load_callback.on_ad_failed_to_load = _on_native_interstitial_failed_to_load

	_content_callback = FullScreenContentCallback.new()
	_content_callback.on_ad_showed_full_screen_content = _on_native_interstitial_showed
	_content_callback.on_ad_dismissed_full_screen_content = _on_native_interstitial_dismissed
	_content_callback.on_ad_failed_to_show_full_screen_content = _on_native_interstitial_failed_to_show

	var request_config := RequestConfiguration.new()
	request_config.test_device_ids = []
	MobileAds.set_request_configuration(request_config)

	var init_listener := OnInitializationCompleteListener.new()
	init_listener.on_initialization_complete = func(_status: InitializationStatus) -> void:
		is_initialized = true
		admob_initialized.emit(true)
		# Defer preload to the next engine frame so JNI signal dispatch can cleanly exit first
		call_deferred("preload_interstitial")

	MobileAds.initialize(init_listener)


func preload_interstitial() -> void:
	if not ads_enabled or is_loading_interstitial or is_interstitial_loaded():
		return

	var unit_id := get_active_interstitial_unit_id()
	if unit_id.is_empty():
		last_error_message = "Empty interstitial ad unit ID"
		interstitial_failed_to_load.emit(last_error_message)
		return

	if _simulation_enabled:
		is_loading_interstitial = true
		if _simulate_load_success:
			is_loading_interstitial = false
			_simulated_ad_ready = true
			last_error_message = ""
			interstitial_loaded.emit(unit_id)
		else:
			is_loading_interstitial = false
			_simulated_ad_ready = false
			last_error_message = "Simulated AdMob no-fill / network error"
			interstitial_failed_to_load.emit(last_error_message)
		return

	if not has_native_android_admob():
		return

	is_loading_interstitial = true
	if _load_callback == null:
		_load_callback = InterstitialAdLoadCallback.new()
		_load_callback.on_ad_loaded = _on_native_interstitial_loaded
		_load_callback.on_ad_failed_to_load = _on_native_interstitial_failed_to_load

	var req := AdRequest.new()
	req.keywords = []
	req.mediation_extras = []
	req.extras = {}

	_interstitial_loader = InterstitialAdLoader.new()
	_interstitial_loader.load(unit_id, req, _load_callback)


## Returns true ONLY when the game is at the post-match result break (MATCH_OVER)
## and not during active gameplay, countdown, aiming, shooting, matchmaking, lobby joining, or room creation.
func is_safe_break_for_interstitial(
	match_phase: int,
	is_in_active_gameplay: bool,
	is_matchmaking_or_lobby_busy: bool
) -> bool:
	if is_in_active_gameplay or is_matchmaking_or_lobby_busy:
		return false
	# MatchController.MatchPhase.MATCH_OVER == 3
	return match_phase == 3


## Attempts to show a loaded interstitial ad ONLY if at a valid post-match break.
## Always invokes `on_continue` whether an ad is shown, fails to load, fails to show, or is skipped.
func show_post_match_interstitial_then(
	match_phase: int,
	is_in_active_gameplay: bool,
	is_matchmaking_or_lobby_busy: bool,
	on_continue: Callable = Callable()
) -> bool:
	# 1. Never show during active gameplay, countdown, aiming, shooting, matchmaking, lobby joining, or room creation
	if not is_safe_break_for_interstitial(match_phase, is_in_active_gameplay, is_matchmaking_or_lobby_busy):
		unsafe_show_attempts_blocked += 1
		interstitial_skipped.emit("UNSAFE_PHASE_BLOCKED")
		if on_continue.is_valid():
			on_continue.call()
		return false

	# 2. If already showing an interstitial, do not stack
	if is_showing_interstitial:
		interstitial_skipped.emit("ALREADY_SHOWING")
		if on_continue.is_valid():
			on_continue.call()
		return false

	# 2b. Frequency cap
	if _last_shown_ms >= 0 and min_interval_sec > 0.0:
		var elapsed := float(Time.get_ticks_msec() - _last_shown_ms) / 1000.0
		if elapsed < min_interval_sec:
			interstitial_skipped.emit("COOLDOWN")
			if on_continue.is_valid():
				on_continue.call()
			return false

	# 3. If no interstitial is loaded (failed to load, offline, or desktop mode), continue immediately
	if not is_interstitial_loaded():
		preload_interstitial()
		interstitial_skipped.emit("AD_NOT_LOADED")
		if on_continue.is_valid():
			on_continue.call()
		return false

	var unit_id := get_active_interstitial_unit_id()

	# 4. Simulated test mode (for automated testing on desktop/headless)
	if _simulation_enabled:
		_simulated_ad_ready = false
		is_showing_interstitial = true
		ads_shown_count += 1
		_last_shown_ms = Time.get_ticks_msec()
		if is_in_active_gameplay:
			ads_shown_during_gameplay_count += 1
		interstitial_shown.emit(unit_id)
		is_showing_interstitial = false
		interstitial_dismissed.emit()
		if on_continue.is_valid():
			on_continue.call()
		preload_interstitial()
		return true

	# 5. Native Android AdMob interstitial display
	if has_native_android_admob() and _interstitial_ad != null:
		_pending_continuation = on_continue
		is_showing_interstitial = true
		ads_shown_count += 1
		_last_shown_ms = Time.get_ticks_msec()
		if is_in_active_gameplay:
			ads_shown_during_gameplay_count += 1
		_interstitial_ad.full_screen_content_callback = _content_callback
		_interstitial_ad.show()
		return true

	if on_continue.is_valid():
		on_continue.call()
	return false


func destroy_interstitial() -> void:
	if _interstitial_ad != null:
		_interstitial_ad.destroy()
		_interstitial_ad = null
	_simulated_ad_ready = false
	is_showing_interstitial = false
	is_loading_interstitial = false


func _exit_tree() -> void:
	destroy_interstitial()


func _on_native_interstitial_loaded(ad: InterstitialAd) -> void:
	is_loading_interstitial = false
	last_error_message = ""
	if _interstitial_ad != null and _interstitial_ad != ad:
		_interstitial_ad.destroy()
	_interstitial_ad = ad
	if _content_callback != null:
		_interstitial_ad.full_screen_content_callback = _content_callback
	interstitial_loaded.emit(get_active_interstitial_unit_id())


func _on_native_interstitial_failed_to_load(error: LoadAdError) -> void:
	is_loading_interstitial = false
	_interstitial_ad = null
	last_error_message = error.message if error != null else "Unknown interstitial load error"
	interstitial_failed_to_load.emit(last_error_message)


func _on_native_interstitial_showed() -> void:
	interstitial_shown.emit(get_active_interstitial_unit_id())


func _on_native_interstitial_dismissed() -> void:
	is_showing_interstitial = false
	destroy_interstitial()
	interstitial_dismissed.emit()
	_invoke_pending_continuation()
	preload_interstitial()


func _on_native_interstitial_failed_to_show(error: AdError) -> void:
	is_showing_interstitial = false
	last_error_message = error.message if error != null else "Failed to show interstitial"
	destroy_interstitial()
	interstitial_failed_to_show.emit(last_error_message)
	_invoke_pending_continuation()
	preload_interstitial()


func _invoke_pending_continuation() -> void:
	if _pending_continuation.is_valid():
		var cb := _pending_continuation
		_pending_continuation = Callable()
		cb.call()
