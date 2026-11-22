extends Node

func _ready() -> void:
    if not "--faf-build-basic-flow" in OS.get_cmdline_user_args():
        queue_free()
        return
    call_deferred("_run_basic_flow")

func _run_basic_flow() -> void:
    var timeout_seconds := 120
    for argument in OS.get_cmdline_user_args():
        if argument.begins_with("--faf-flow-timeout="):
            timeout_seconds = maxi(1, argument.trim_prefix("--faf-flow-timeout=").to_int())
    var deadline := Time.get_ticks_msec() + timeout_seconds * 1000
    while get_tree().current_scene == null and Time.get_ticks_msec() < deadline:
        await get_tree().process_frame
    var game := get_tree().current_scene
    if game == null or not game.has_method("start_new_game"):
        _fail("Main scene does not provide start_new_game")
        return
    var constants: Dictionary = game.get_script().get_script_constant_map()
    var states: Dictionary = constants.get("SessionState", {})
    if not states.has("Running"):
        _fail("Main scene does not expose SessionState.Running")
        return
    game.call("start_new_game")
    while Time.get_ticks_msec() < deadline:
        if game.get("session_state") == states["Running"] and game.get("level_prepared") == true:
            if game.get("player") == null or game.get("current_level_instance") == null:
                _fail("Running game is missing its player or loaded level")
                return
            print("FAF_BASIC_FLOW_PASSED: new game started, player and level ready, normal exit")
            get_tree().quit(0)
            return
        await get_tree().process_frame
    _fail("New game did not reach Running with a prepared level before timeout")

func _fail(message: String) -> void:
    push_error("FAF_BASIC_FLOW_FAILED: " + message)
    get_tree().quit(1)