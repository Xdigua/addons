@tool
extends EditorPlugin

## 配置工坊 · 插件入口
##
## 面板有两种承载方式，同一个 Control 实例在两者之间来回搬（不重建、不丢编辑状态）：
##   - 浮窗（默认）：独立 Window，可拖出编辑器、可缩放、不置顶；X 只是隐藏；
##   - 侧边栏：注册成编辑器 dock，跟着编辑器布局一起保存。
## 切换入口在面板标题栏右上角，菜单里只有一个「配置工坊」负责把面板叫出来。
##
## 插件在宿主工程里只落一个根目录（ROOT_DIR）：
##   configforge/schema.json   结构定义
##   configforge/Data/         数据源
##   configforge/cfg/          生成代码
##   configforge/data/         生成数据
## 首次启用时从内置 defaults 铺一份示例（已有则绝不覆盖），并跑一次生成。
##
## 时序很重要：所有 UI 操作都放在 _startup()（call_deferred）里，
## 不在 EditorNode 构造期创建 native Window / 读编辑器主题 —— 那样会让编辑器启动卡住。
##
## 面板本体在 ui/dock_main.gd（历史文件名，现在是一个普通 Control），
## 管线在 core/cf_pipeline.gd，两者都不依赖 EditorPlugin，
## 所以同一套逻辑也能在 headless CLI 里跑。

const ADDON_DIR := "res://addons/configforge"
const DEFAULTS_DIR := "res://addons/configforge/defaults"
const PANEL_PATH := "res://addons/configforge/ui/dock_main.gd"

## 插件在宿主工程里只落这一个根目录：
##   configforge/schema.json   结构定义
##   configforge/data/         数据源
##   configforge/out/          生成物（schema.gd / loader.gd / 各表 json）
const ROOT_DIR := "res://configforge"

const WINDOW_TITLE := "配置工坊"
const WINDOW_SIZE := Vector2i(1120, 720)
const WINDOW_MIN_SIZE := Vector2i(780, 480)

## 菜单里只保留这一项：能把面板叫出来就够了。
const MENU_OPEN := "配置工坊"

const MODE_WINDOW := "window"
const MODE_DOCK := "dock"

## 默认以浮窗打开：工具是「随手看一眼/改一下」的，浮窗不占侧边栏。
## 面板标题栏右上角可以切回侧边栏，切换是同一个实例搬家，编辑状态不丢。
const DEFAULT_MODE := MODE_WINDOW

var _window: Window = null
var _panel: Control = null
var _mode := DEFAULT_MODE
var _bootstrap_tries := 0
## 面板当前是否真的挂在编辑器 dock 上。
## remove_control_from_docks() 对「没注册过的控件」会触发
## editor_plugin.cpp 的 "!legacy_docks.has(p_control)" 断言，所以必须自己记账。
var _docked := false


func _enter_tree() -> void:
	# 这里只做「不碰文件系统」的事：写文件放到 _startup（延迟到编辑器就绪之后），
	# 否则构造期创建目录会触发文件系统变更 → 插件被重复启用
	# （editor_node.cpp: "addon_name_to_plugin.has(addon_path)"）。
	add_tool_menu_item(MENU_OPEN, Callable(self, "_menu_open"))
	call_deferred("_startup")


## 延迟启动：此时编辑器 UI 已就绪，建 dock / 浮窗 / 读主题都安全。
func _startup() -> void:
	print("[配置工坊] 开始初始化…")
	# 首次启用时把示例铺到 res://cfg_src/（已有则绝不覆盖）——
	# 放在这里而不是 _enter_tree，避免在编辑器构造期写文件。
	_ensure_project_defaults()
	if _panel == null or not is_instance_valid(_panel):
		if not _build_panel():
			print("[配置工坊] 面板脚本暂未加载成功，稍后自动重试（冷启动时全局类缓存可能还没写完）")
			_retry_panel(0)
			return
	if _window == null or not is_instance_valid(_window):
		_build_window()
	_apply_mode(DEFAULT_MODE, true)
	print("[配置工坊] 初始化完成（模式：%s）" % _mode)
	_bootstrap_generate()


## 面板加载失败时的自动重试：冷启动（刚删过 .godot）时编辑器的文件系统扫描还没把
## class_name 注册完，按类名引用会报 Parse error；等扫描结束后再试就能加载。
func _retry_panel(attempt: int) -> void:
	if _panel != null and is_instance_valid(_panel):
		return
	if attempt >= 8:
		print("[配置工坊] 面板重试 %d 次仍失败，已放弃" % attempt)
		_report_script_failures()
		return
	# 冷启动（刚删过 .godot）时，class_name 要等文件系统扫描注册完才能解析，
	# 所以这里等扫描结束再试，而不是干等固定时长。
	var fs := EditorInterface.get_resource_filesystem()
	if fs != null and fs.is_scanning():
		await fs.filesystem_changed
	else:
		await get_tree().create_timer(0.3).timeout
	if _build_panel(true):
		print("[配置工坊] 面板已延迟加载成功（第 %d 次重试）" % (attempt + 1))
		if _window == null or not is_instance_valid(_window):
			_build_window()
		_apply_mode(DEFAULT_MODE, true)
		_bootstrap_generate()
		return
	_retry_panel(attempt + 1)


func _exit_tree() -> void:
	remove_tool_menu_item(MENU_OPEN)

	if _docked and _panel != null and is_instance_valid(_panel):
		remove_control_from_docks(_panel)
	_docked = false
	if _window != null and is_instance_valid(_window):
		_window.queue_free()
		_window = null
	if _panel != null and is_instance_valid(_panel):
		_panel.queue_free()
		_panel = null


# ---------------------------------------------------------------- 面板 / 浮窗

## 创建面板（只建一次）。注意这里**不**把它挂进任何容器，等 _apply_mode 决定去处。
## quiet=true 用于自动重试：只在第一次失败时打错误，避免刷屏。
func _build_panel(quiet: bool = false) -> bool:
	if _panel != null and is_instance_valid(_panel):
		return true
	# CACHE_MODE_IGNORE：编译失败的脚本会被缓存成「无效资源」，
	# 后续重试若命中缓存就永远好不了，所以这里强制从磁盘重新解析。
	var panel_script: GDScript = ResourceLoader.load(PANEL_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
	if panel_script == null:
		if not quiet:
			push_error("配置工坊：面板脚本加载失败（" + PANEL_PATH + "）。"
				+ "请把 Output 里这句上面的「Parse Error: … at: …:行号」发出来，按行号定位最快。")
		return false
	if not panel_script.can_instantiate():
		if not quiet:
			print("配置工坊：面板脚本编译还没通过（多半是全局类尚未注册完），稍后自动重试")
		return false
	_panel = panel_script.new()
	if _panel == null:
		push_error("配置工坊：面板脚本实例化失败")
		return false
	_panel.name = "ConfigForgePanel"
	# 面板靠这个引用回调 set_mode/get_mode 来切换浮窗与侧边栏
	_panel.set("host", self)
	return true


## 面板加载失败时，逐个试加载它依赖的脚本，把「到底是哪个文件坏了」直接打到 Output。
## 面板引用了 9 个 CF* 全局类，任何一个坏了都会让面板加载失败，但报错往往只指出面板本身。
func _report_script_failures() -> void:
	var paths: Array = [
		"res://addons/configforge/core/cf_issue.gd",
		"res://addons/configforge/core/cf_types.gd",
		"res://addons/configforge/core/cf_csv.gd",
		"res://addons/configforge/core/cf_schema.gd",
		"res://addons/configforge/core/cf_loader.gd",
		"res://addons/configforge/core/cf_validator.gd",
		"res://addons/configforge/core/cf_codegen.gd",
		"res://addons/configforge/core/cf_pipeline.gd",
		"res://addons/configforge/ui/cf_theme.gd",
	]
	var broken: Array = []
	for p in paths:
		if load(str(p)) == null:
			broken.append(str(p))
	if broken.is_empty():
		push_error("配置工坊：依赖脚本都能单独加载，问题只在面板脚本本身（" + PANEL_PATH + "）")
		return
	for p in broken:
		push_error("配置工坊：↓ 这个依赖脚本坏了，先修它 → " + str(p))


## 创建浮窗（只建一次）。窗口本身常驻，只是显示/隐藏。
func _build_window() -> void:
	if _window != null and is_instance_valid(_window):
		return
	_window = Window.new()
	_window.name = "ConfigForgeWindow"
	_window.title = WINDOW_TITLE
	_window.size = WINDOW_SIZE
	_window.min_size = WINDOW_MIN_SIZE
	# 普通浮窗：不置顶、非 transient，可被其它窗口正常覆盖
	_window.always_on_top = false
	_window.transient = false
	_window.exclusive = false
	_window.wrap_controls = false
	_window.visible = false
	_window.close_requested.connect(_on_window_close_requested)
	# 挂到编辑器根节点：随编辑器一起释放，也不属于任何场景
	get_tree().root.add_child(_window)


## 把面板铺满父容器（dock 里用不到，但设了无害；浮窗里靠它自适应缩放）。
func _fill_parent(control: Control) -> void:
	control.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	control.size_flags_vertical = Control.SIZE_EXPAND_FILL


## 在「浮窗 / 侧边栏」之间切换：把同一个面板实例搬过去，编辑状态不丢。
## force = true 时即使模式相同也重新挂一遍（用来把关掉的 dock 页签重新叫出来）。
func _apply_mode(mode: String, force := false) -> void:
	if _panel == null or not is_instance_valid(_panel):
		if not _build_panel():
			return
	if _window == null or not is_instance_valid(_window):
		_build_window()
	if not force and mode == _mode and _mode == MODE_WINDOW:
		_show_window()
		return

	# 1) 从旧容器摘下来（只在确实挂过 dock 时才摘，否则编辑器会报 legacy_docks 断言）
	if _docked and _panel != null and is_instance_valid(_panel):
		remove_control_from_docks(_panel)
	_docked = false
	var parent := _panel.get_parent()
	if parent != null:
		parent.remove_child(_panel)

	# 2) 挂到新容器
	_mode = mode
	if mode == MODE_DOCK:
		if _window != null and is_instance_valid(_window):
			_window.hide()
		add_control_to_dock(DOCK_SLOT_RIGHT_UL, _panel)
		_docked = true
		_fill_parent(_panel)
		_panel.show()
	else:
		if _window != null and is_instance_valid(_window):
			_window.add_child(_panel)
			_fill_parent(_panel)
		_show_window()
	_refresh_mode_button()


## 显示浮窗：已经可见就什么都不做（保留用户拖动/缩放后的位置与大小）。
func _show_window() -> void:
	if _window == null or not is_instance_valid(_window):
		_build_window()
	if _window == null or not is_instance_valid(_window):
		return
	if _window.visible:
		return
	var size := _window.size
	if size.x < WINDOW_MIN_SIZE.x or size.y < WINDOW_MIN_SIZE.y:
		size = WINDOW_SIZE
	var pos := Vector2i(160, 120)
	var base := EditorInterface.get_base_control()
	if base != null:
		var main_window: Window = base.get_window()
		if main_window != null:
			pos = main_window.position + Vector2i(160, 120)
	_window.popup(Rect2i(pos, size))


## 右上角 X：只是隐藏，不销毁（菜单可再打开）。
func _on_window_close_requested() -> void:
	if _window != null and is_instance_valid(_window):
		_window.hide()


# ---------------------------------------------------------------- 菜单 / 模式

## 菜单里唯一的入口：把面板叫出来。
## 浮窗模式下就是弹窗；停靠模式下会重新挂一遍，所以用户把 dock 页签关掉了也能点回来。
func _menu_open() -> void:
	if _panel == null or not is_instance_valid(_panel):
		if not _build_panel():
			return
	if _window == null or not is_instance_valid(_window):
		_build_window()
	if _mode == MODE_DOCK:
		_apply_mode(MODE_DOCK, true)
	else:
		_show_window()


## 当前承载方式：MODE_WINDOW / MODE_DOCK（面板顶部的切换按钮会读它）。
func get_mode() -> String:
	return _mode


## 切换承载方式（面板顶部按钮调用）。
func set_mode(mode: String) -> void:
	if mode != MODE_DOCK and mode != MODE_WINDOW:
		return
	if mode == _mode:
		# 同模式再切一次：浮窗就确保可见，dock 就重新挂一遍（相当于重开页签）
		if mode == MODE_WINDOW:
			_show_window()
		else:
			_apply_mode(MODE_DOCK, true)
		return
	_apply_mode(mode)


## 让面板刷新它的「停靠/浮窗」按钮文案。
func _refresh_mode_button() -> void:
	if _panel != null and is_instance_valid(_panel) and _panel.has_method("refresh_mode_button"):
		_panel.call("refresh_mode_button")


# ---------------------------------------------------------------- 首次初始化

## 工程里还没有 configforge/schema.json 时，从插件内置 defaults 复制一份示例
## （已有则跳过，绝不覆盖）。
func _ensure_project_defaults() -> void:
	if FileAccess.file_exists(ROOT_DIR + "/schema.json"):
		return
	if not FileAccess.file_exists(DEFAULTS_DIR + "/schema.json"):
		return
	var data_target := ROOT_DIR + "/data"
	var mk := DirAccess.make_dir_recursive_absolute(data_target)
	if mk != OK and not DirAccess.dir_exists_absolute(data_target):
		push_error("配置工坊：无法创建 %s（err=%d）" % [data_target, mk])
		return
	var ok := true
	if DirAccess.copy_absolute(DEFAULTS_DIR + "/schema.json", ROOT_DIR + "/schema.json") != OK:
		ok = false
	var sub := DirAccess.open(DEFAULTS_DIR + "/data")
	if sub == null:
		ok = false
	else:
		# .gdignore 是隐藏文件：必须打开 include_hidden 才会被复制过去，
		# 否则新工程的数据目录会被 Godot 当成 CSV 翻译表导入
		sub.include_hidden = true
		for file_name in sub.get_files():
			if file_name.ends_with(".uid"):
				continue
			if DirAccess.copy_absolute(DEFAULTS_DIR + "/Data/" + file_name, data_target + "/" + file_name) != OK:
				ok = false
	if ok:
		print("配置工坊：已初始化 %s/（schema.json + 数据源）" % ROOT_DIR)
	else:
		push_warning("配置工坊：初始化 %s/ 时部分文件复制失败，请检查插件目录是否完整" % ROOT_DIR)


## 生成物是否比生成器新：生成器源码改过就重新生成一次，避免旧产物留在盘上报解析错误。
func _is_output_fresh() -> bool:
	var out := ROOT_DIR + "/cfg/schema.gd"
	if not FileAccess.file_exists(out):
		return false
	var out_time := FileAccess.get_modified_time(out)
	var newest := 0
	for p in ["res://addons/configforge/core/cf_codegen.gd", "res://addons/configforge/core/cf_loader.gd"]:
		if FileAccess.file_exists(p):
			newest = maxi(newest, FileAccess.get_modified_time(p))
	return out_time >= newest


## 首次启用跑一次生成。
## 刻意不直接引用 CFPipeline / CFIssue 这类 class_name，而是通过面板暴露的方法间接触发：
## 全新工程（还没有 .godot 全局类缓存）首次启动时，直接引用会解析失败。
func _bootstrap_generate() -> void:
	if not FileAccess.file_exists(ROOT_DIR + "/schema.json"):
		return
	if _is_output_fresh():
		return
	if _panel == null or not is_instance_valid(_panel):
		return
	if not _panel.has_method("run_generate_silent"):
		return

	_bootstrap_tries += 1
	var outcome: Variant = _panel.call("run_generate_silent")
	var ok := false
	var stage := ""
	if outcome is Dictionary:
		ok = bool(outcome.get("ok", false))
		stage = str(outcome.get("stage", ""))

	# 写入阶段失败多半是「编辑器刚启动、文件系统还在扫描」这类瞬时状态，隔一会儿再试两次。
	# 这里用定时器而不是 call_deferred：deferred 调用期间编辑器不允许开进度任务（scan 会开）。
	if not ok and stage == "generate" and _bootstrap_tries < 3:
		await get_tree().create_timer(0.5).timeout
		_bootstrap_generate()
