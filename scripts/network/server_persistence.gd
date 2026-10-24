class_name ServerPersistence
extends RefCounted
## Server-side persistent storage for player accounts, unique usernames,
## match statistics (wins, losses, draws, matches played, eliminations),
## match history, and the global leaderboard.
## All stat updates are server-validated from authoritative ServerMatchSession outcomes.

const DEFAULT_SAVE_PATH: String = "user://server_persistence.json"
const MAX_PLAYER_HISTORY: int = 15
const MAX_GLOBAL_HISTORY: int = 50

var save_path: String = DEFAULT_SAVE_PATH

# username (String) -> {
#   "username": String,
#   "token_hash": String,
#   "wins": int,
#   "losses": int,
#   "draws": int,
#   "matches_played": int,
#   "eliminations": int,
#   "match_history": Array[Dictionary]
# }
var accounts: Dictionary = {}
var global_match_history: Array[Dictionary] = []


func _init(custom_save_path: String = DEFAULT_SAVE_PATH) -> void:
	save_path = custom_save_path
	load_from_disk()


func load_from_disk() -> void:
	if save_path.is_empty() or not FileAccess.file_exists(save_path):
		return
	var f := FileAccess.open(save_path, FileAccess.READ)
	if not f:
		return
	var text := f.get_as_text()
	f.close()
	if text.strip_edges().is_empty():
		return
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	if data.has("accounts") and typeof(data["accounts"]) == TYPE_DICTIONARY:
		accounts = data["accounts"]
	if data.has("global_match_history") and typeof(data["global_match_history"]) == TYPE_ARRAY:
		global_match_history.clear()
		for item in data["global_match_history"]:
			if typeof(item) == TYPE_DICTIONARY:
				global_match_history.append(item)


func save_to_disk() -> bool:
	if save_path.is_empty():
		return false
	var f := FileAccess.open(save_path, FileAccess.WRITE)
	if not f:
		return false
	var payload := {
		"version": 1,
		"accounts": accounts,
		"global_match_history": global_match_history
	}
	f.store_string(JSON.stringify(payload, "\t"))
	f.close()
	return true


## Registers a new username or authenticates an existing username via secret client token.
## If the requested username is already owned by a different token, assigns a unique suffix
## so another client cannot impersonate or overwrite an existing player's account.
func authenticate_or_register_player(
	requested_name: String,
	raw_token: String,
	fallback_peer_id: int
) -> Dictionary:
	var base_name := NetProtocol.sanitize_player_name(requested_name, "P_%d" % fallback_peer_id)
	var token_clean := raw_token.strip_edges()
	if token_clean.is_empty():
		token_clean = "anon_peer_%d" % fallback_peer_id
	var token_hash := token_clean.sha256_text()

	var resolved_name := base_name
	if accounts.has(base_name):
		var existing: Dictionary = accounts[base_name]
		if str(existing.get("token_hash", "")) == token_hash:
			# Returning owner of this username
			return get_public_profile(base_name)
		else:
			# Username belongs to another token — find an available unique suffix
			var suffix := 2
			while suffix < 1000:
				var candidate := "%s_%d" % [base_name.left(12), suffix]
				if not accounts.has(candidate):
					resolved_name = candidate
					break
				elif str(accounts[candidate].get("token_hash", "")) == token_hash:
					resolved_name = candidate
					return get_public_profile(resolved_name)
				suffix += 1

	accounts[resolved_name] = {
		"username": resolved_name,
		"token_hash": token_hash,
		"wins": 0,
		"losses": 0,
		"draws": 0,
		"matches_played": 0,
		"eliminations": 0,
		"match_history": []
	}
	save_to_disk()
	return get_public_profile(resolved_name)


func get_public_profile(username: String) -> Dictionary:
	if not accounts.has(username):
		return {
			"username": username,
			"wins": 0,
			"losses": 0,
			"draws": 0,
			"matches_played": 0,
			"eliminations": 0,
			"match_history": []
		}
	var acc: Dictionary = accounts[username]
	return {
		"username": str(acc.get("username", username)),
		"wins": int(acc.get("wins", 0)),
		"losses": int(acc.get("losses", 0)),
		"draws": int(acc.get("draws", 0)),
		"matches_played": int(acc.get("matches_played", 0)),
		"eliminations": int(acc.get("eliminations", 0)),
		"match_history": (acc.get("match_history", []) as Array).duplicate(true)
	}


## Updates player statistics exclusively from an authoritative ServerMatchSession summary.
func record_authoritative_match(summary: Dictionary) -> void:
	var session_id := str(summary.get("session_id", "match"))
	var is_draw := bool(summary.get("is_draw", false))
	var winner_slot := int(summary.get("winner_slot_id", -1))
	var winner_name := str(summary.get("winner_name", "NONE" if is_draw else "UNKNOWN"))
	var rounds := int(summary.get("rounds_completed", 1))
	var final_stage := int(summary.get("final_stage", 1))
	var timestamp := Time.get_datetime_string_from_system(true)

	var slots: Array = summary.get("slots", [])
	var participant_names: Array[String] = []

	for s in slots:
		if typeof(s) != TYPE_DICTIONARY or not bool(s.get("active", false)):
			continue
		var p_name := str(s.get("name", ""))
		participant_names.append(p_name)

		if not bool(s.get("is_human", false)):
			continue

		if not accounts.has(p_name):
			accounts[p_name] = {
				"username": p_name,
				"token_hash": "",
				"wins": 0,
				"losses": 0,
				"draws": 0,
				"matches_played": 0,
				"eliminations": 0,
				"match_history": []
			}

		var acc: Dictionary = accounts[p_name]
		var slot_id := int(s.get("slot_id", -1))
		var elims := int(s.get("eliminations", 0))

		acc["matches_played"] = int(acc.get("matches_played", 0)) + 1
		acc["eliminations"] = int(acc.get("eliminations", 0)) + elims

		var outcome := "LOSS"
		if is_draw:
			acc["draws"] = int(acc.get("draws", 0)) + 1
			outcome = "DRAW"
		elif slot_id == winner_slot:
			acc["wins"] = int(acc.get("wins", 0)) + 1
			outcome = "WIN"
		else:
			acc["losses"] = int(acc.get("losses", 0)) + 1
			outcome = "LOSS"

		var p_hist: Array = acc.get("match_history", [])
		p_hist.push_front({
			"session_id": session_id,
			"timestamp": timestamp,
			"outcome": outcome,
			"winner_name": winner_name,
			"eliminations": elims,
			"rounds": rounds,
			"final_stage": final_stage
		})
		while p_hist.size() > MAX_PLAYER_HISTORY:
			p_hist.pop_back()
		acc["match_history"] = p_hist

	global_match_history.push_front({
		"session_id": session_id,
		"timestamp": timestamp,
		"is_draw": is_draw,
		"winner_name": winner_name,
		"rounds": rounds,
		"final_stage": final_stage,
		"participants": participant_names
	})
	while global_match_history.size() > MAX_GLOBAL_HISTORY:
		global_match_history.pop_back()

	save_to_disk()


func get_leaderboard(limit: int = 20) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	for uname in accounts.keys():
		var acc: Dictionary = accounts[uname]
		var mp := int(acc.get("matches_played", 0))
		var wins := int(acc.get("wins", 0))
		var losses := int(acc.get("losses", 0))
		var draws := int(acc.get("draws", 0))
		var elims := int(acc.get("eliminations", 0))
		rows.append({
			"username": str(acc.get("username", uname)),
			"wins": wins,
			"losses": losses,
			"draws": draws,
			"matches_played": mp,
			"eliminations": elims
		})

	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if int(a["wins"]) != int(b["wins"]):
			return int(a["wins"]) > int(b["wins"])
		if int(a["eliminations"]) != int(b["eliminations"]):
			return int(a["eliminations"]) > int(b["eliminations"])
		return int(a["matches_played"]) > int(b["matches_played"])
	)

	var out: Array[Dictionary] = []
	for i in range(mini(limit, rows.size())):
		var r := rows[i].duplicate()
		r["rank"] = i + 1
		out.append(r)
	return out
