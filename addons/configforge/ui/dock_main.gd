@tool
extends VBoxContainer

## 配置工坊 · 主面板
##
## 纯代码构建的 Control，没有 .tscn。挂到 dock 还是放进独立 Window 由 plugin.gd 决定，
## 两边共用同一个实例，切换时编辑状态不丢。
##
## 四个页签对应管线四段：表数据编辑、结构编辑、校验结果、运行日志。
## 依赖只到 core/ 的管线（CFPipeline / CFIssue / CFDataLoader），
## 界面状态（当前表、展开节点、字号、双击编辑中的格子）都收敛在本类里。

const VERSION := "1.0.0"

const COLOR_ACCENT := Color(0.34, 0.60, 0.86, 1.0)

## 选中态用的强调色（深色主题 / 浅色主题各一个）。
## 想再暗一点就改这两个值，只影响「选中行 / 按下 / 悬停描边」，不影响其它配色。
const ACCENT_DARK := Color(0.24, 0.50, 0.78, 1.0)
const ACCENT_LIGHT := Color(0.12, 0.34, 0.60, 1.0)
const COLOR_OK := Color(0.52, 0.87, 0.60, 1.0)
const COLOR_WARN := Color(1.0, 0.78, 0.36, 1.0)
const COLOR_ERR := Color(1.0, 0.45, 0.45, 1.0)
const COLOR_DIM := Color(0.62, 0.68, 0.76, 1.0)

const TAB_TABLES := 0
const TAB_SCHEMA := 1
const TAB_ISSUES := 2
const TAB_LOG := 3

const SETTING_FONT := "configforge/ui_font_size"
const FONT_MIN := 12
const FONT_MAX := 26
const FONT_DEFAULT := 16

## 由 plugin.gd 注入（_panel.set("host", self)），面板靠它切换浮窗 / 侧边栏。
var host: Node = null

var _pipeline := CFPipeline.new()

var _tab: TabContainer
var _status: Label
var _title_label: Label
var _subtitle_label: Label
var _mode_btn: Button
var _merge_check: CheckBox
var _font_label: Label

var _table_pick: OptionButton
var _import_menu: MenuButton
var _format_pick: OptionButton
var _search: LineEdit
var _grid: Tree
var _table_info: Label

var _schema_tree: Tree
var _schema_search: LineEdit
var _schema_count: Label

# 「字段属性」弹窗（点「字段属性…」打开；改 min/max/长度/ref/sep/正则/资源路径）
var _field_dialog: Window
var _fx_title: Label
var _fx_type: LineEdit
var _fx_min: LineEdit
var _fx_max: LineEdit
var _fx_len_min: LineEdit
var _fx_len_max: LineEdit
var _fx_ref: OptionButton
var _fx_sep: LineEdit
var _fx_pattern: LineEdit
var _fx_path: LineEdit
var _fx_bean := ""
var _fx_index := -1
var _fx_name := ""
var _issue_tree: Tree
var _log_view: RichTextLabel

var _current_table := ""
var _grid_fields: Array = []
var _schema_edits := 0
var _syncing := false
var _ref_cache: Dictionary = {}

var _dialog: FileDialog
var _dialog_action := ""
var _import_mode := "replace"
var _path_dialog: AcceptDialog = null
var _path_edit: LineEdit = null
## 记住上次导入/导出所在的目录，下次打开对话框直接落在那儿
var _last_io_dir := ""

# 双击编辑用的内嵌输入框（每个 Tree 一个）
var _cell_editors: Dictionary = {}
var _edit_tree: Tree = null
var _edit_item: TreeItem = null
var _edit_col := -1

var _built := false
var _font_size := FONT_DEFAULT
## 当前主题推导出来的强调色 / 次要文字色（标题、副标题、状态栏、提示文字都用它们）
var _accent_color := COLOR_ACCENT
var _dim_color := COLOR_DIM


# ---------------------------------------------------------------- 生命周期

func _ready() -> void:
	# 面板会在「浮窗 ⇄ 侧边栏」之间被搬来搬去，UI 只建一次
	if _built:
		return
	_built = true
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_load_font_setting()
	_build_ui()
	if _tab == null:
		push_error("配置工坊：面板 UI 构建失败（见上面第一条错误）")
		return
	reload_all()


# ---------------------------------------------------------------- 构建界面

func _build_ui() -> void:
	theme = _make_theme(_font_size)
	add_theme_constant_override("separation", 4)

	_title_label = Label.new()
	_title_label.text = "配置工坊"
	_title_label.add_theme_font_size_override("font_size", _font_size + 5)
	_title_label.add_theme_color_override("font_color", _accent_color)

	_subtitle_label = Label.new()
	_subtitle_label.text = "v%s" % VERSION
	_subtitle_label.add_theme_font_size_override("font_size", _font_size - 3)
	_subtitle_label.add_theme_color_override("font_color", _dim_color)

	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 10)
	title_row.add_child(_title_label)
	title_row.add_child(_subtitle_label)
	var title_spacer := Control.new()
	title_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title_row.add_child(title_spacer)
	_mode_btn = _add_button(title_row, "⇲ 停靠侧边栏", Callable(self, "_on_toggle_mode"))
	add_child(title_row)

	var toolbar := HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 6)
	add_child(toolbar)
	_add_button(toolbar, "重新加载", Callable(self, "reload_all"))
	_add_button(toolbar, "校验", Callable(self, "run_validate"))
	_add_button(toolbar, "一键生成", Callable(self, "run_generate"))

	_merge_check = CheckBox.new()
	_merge_check.text = "数据合并为单文件"
	# 默认不合并：每张表一个 data/<表名>.json，改动/热更时只换一个文件
	_merge_check.button_pressed = false
	_merge_check.focus_mode = Control.FOCUS_NONE
	_merge_check.tooltip_text = "勾选：所有表写进 data/config.json；不勾：每张表一个 data/<表名>.json"
	toolbar.add_child(_merge_check)

	var toolbar_spacer := Control.new()
	toolbar_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	toolbar.add_child(toolbar_spacer)

	toolbar.add_child(_dim_label("字号"))
	var font_down := _add_button(toolbar, "A-", Callable(self, "_font_smaller"))
	font_down.tooltip_text = "缩小界面字号"
	_font_label = Label.new()
	_font_label.text = str(_font_size)
	_font_label.custom_minimum_size = Vector2(28, 0)
	toolbar.add_child(_font_label)
	var font_up := _add_button(toolbar, "A+", Callable(self, "_font_bigger"))
	font_up.tooltip_text = "放大界面字号"

	_tab = TabContainer.new()
	_tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tab.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_tab)

	_build_tables_page()
	_build_schema_page()
	_build_issues_page()
	_build_log_page()

	_status = Label.new()
	_status.text = "就绪"
	_status.add_theme_font_size_override("font_size", _font_size - 3)
	_status.add_theme_color_override("font_color", _dim_color)
	add_child(_status)


func _add_button(parent: Node, text: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(callback)
	parent.add_child(button)
	return button


func _dim_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", _dim_color)
	return label


## 主题 = 字号 + 明确的选中/悬停/按下状态。
## 底色和文字色从编辑器主题推导（取不到就用中性深色），选中态自己定：
## 编辑器默认的选中样式太淡，看不出选的是哪一行。
func _make_theme(size: int) -> Theme:
	var fs := size
	if fs < FONT_MIN:
		fs = FONT_MIN
	if fs > FONT_MAX:
		fs = FONT_MAX

	var bg := Color(0.13, 0.15, 0.18, 1.0)
	var fg := Color(0.88, 0.90, 0.93, 1.0)
	if Engine.is_editor_hint():
		var et: Theme = EditorInterface.get_editor_theme()
		if et != null:
			var pb: StyleBox = et.get_stylebox("panel", "PanelContainer")
			if pb is StyleBoxFlat:
				bg = (pb as StyleBoxFlat).bg_color
			var lc: Color = et.get_color("font_color", "Label")
			if lc.a > 0.0:
				fg = lc

	var dark := bg.get_luminance() < 0.5
	var surface := bg.lightened(0.06)
	var border := bg.lightened(0.20)
	var accent := ACCENT_DARK
	var on_accent := Color(1, 1, 1, 1)
	if not dark:
		surface = bg.darkened(0.04)
		border = bg.darkened(0.18)
		accent = ACCENT_LIGHT
	var tint := Color(accent.r, accent.g, accent.b, 0.22)
	var row_fill := accent.darkened(0.12)
	var dim := fg.lerp(bg, 0.35)
	# 记下来给标题 / 副标题 / 状态栏 / 提示文字用，避免界面里出现两套蓝
	_accent_color = accent
	_dim_color = dim

	var th := Theme.new()
	th.default_font_size = fs
	th.set_font_size("font_size", "Label", fs)
	th.set_font_size("font_size", "Button", fs)
	th.set_font_size("font_size", "OptionButton", fs)
	th.set_font_size("font_size", "CheckBox", fs)
	th.set_font_size("font_size", "LineEdit", fs)
	th.set_font_size("font_size", "Tree", fs)
	th.set_font_size("font_size", "TabContainer", fs)
	th.set_font_size("font_size", "RichTextLabel", fs - 1)
	th.set_constant("v_separation", "Tree", 8)
	th.set_constant("h_separation", "Tree", 10)

	# ---- 容器 / 文字
	th.set_stylebox("panel", "PanelContainer", _box(surface, border, 6, 1, 10, 8))
	th.set_color("font_color", "Label", fg)

	# ---- 表格：选中行整块强调色 + 白字，一眼就能看出选的是哪行（比按钮的强调色再暗一档）
	var row_sel := _box(row_fill, accent, 4, 1, 2, 1)
	th.set_stylebox("selected", "Tree", row_sel)
	th.set_stylebox("selected_focus", "Tree", row_sel)
	th.set_stylebox("cursor", "Tree", _box(tint, accent, 4, 1, 2, 1))
	th.set_stylebox("cursor_unfocused", "Tree", _box(Color(0, 0, 0, 0), border, 4, 1, 2, 1))
	th.set_stylebox("panel", "Tree", _box(bg, border, 6, 1, 4, 4))
	th.set_color("font_selected_color", "Tree", on_accent)
	th.set_color("font_color", "Tree", fg)
	th.set_color("title_button_color", "Tree", dim)
	th.set_color("guide_color", "Tree", Color(1, 1, 1, 0.06))

	# ---- 按钮 / 下拉：悬停描边+底色，按下实心强调色
	# MenuButton 是独立的主题类型（不继承 Button 的样式），三个都要显式给
	_set_button_theme(th, "Button", surface, border, accent, tint, on_accent, fg, dim)
	_set_button_theme(th, "OptionButton", surface, border, accent, tint, on_accent, fg, dim)
	_set_button_theme(th, "MenuButton", surface, border, accent, tint, on_accent, fg, dim)

	# ---- 复选框：勾选后整行文字变强调色，好辨认
	th.set_stylebox("normal", "CheckBox", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 4, 0, 4, 2))
	th.set_stylebox("hover", "CheckBox", _box(tint, Color(0, 0, 0, 0), 4, 0, 4, 2))
	th.set_stylebox("pressed", "CheckBox", _box(tint, accent, 4, 1, 4, 2))
	th.set_color("font_color", "CheckBox", fg)
	th.set_color("font_hover_color", "CheckBox", fg)
	th.set_color("font_pressed_color", "CheckBox", accent)
	th.set_color("font_hover_pressed_color", "CheckBox", accent)

	# ---- 输入框：聚焦时强调色边框
	th.set_stylebox("normal", "LineEdit", _box(bg, border, 4, 1, 8, 4))
	th.set_stylebox("focus", "LineEdit", _box(bg, accent, 4, 2, 8, 4))
	th.set_color("font_color", "LineEdit", fg)
	th.set_color("font_placeholder_color", "LineEdit", dim)
	th.set_color("caret_color", "LineEdit", accent)
	th.set_color("selection_color", "LineEdit", tint)
	th.set_stylebox("normal", "RichTextLabel", _box(bg, border, 6, 1, 8, 6))
	th.set_color("default_color", "RichTextLabel", fg)

	# ---- 页签：选中项强调色文字 + 底部下划线
	th.set_stylebox("tab_selected", "TabContainer", _tab_box(Color(0, 0, 0, 0), accent))
	th.set_stylebox("tab_unselected", "TabContainer", _tab_box(Color(0, 0, 0, 0), Color(0, 0, 0, 0)))
	th.set_stylebox("tab_hovered", "TabContainer", _tab_box(tint, Color(0, 0, 0, 0)))
	th.set_stylebox("panel", "TabContainer", _box(bg, border, 6, 1, 8, 8))
	th.set_color("font_selected_color", "TabContainer", accent)
	th.set_color("font_unselected_color", "TabContainer", dim)
	th.set_color("font_hovered_color", "TabContainer", fg)

	# ---- 下拉列表（OptionButton / MenuButton 点开的那层）：项间距 + 悬停项强调色
	th.set_constant("v_separation", "PopupMenu", 6)
	th.set_constant("h_separation", "PopupMenu", 8)
	th.set_constant("item_start_padding", "PopupMenu", 10)
	th.set_constant("item_end_padding", "PopupMenu", 10)
	th.set_stylebox("hover", "PopupMenu", _box(accent, accent, 4, 0, 10, 4))
	th.set_color("font_hover_color", "PopupMenu", on_accent)
	th.set_color("font_color", "PopupMenu", fg)
	th.set_stylebox("panel", "PopupMenu", _box(surface, border, 6, 1, 6, 6))
	return th


## 一套按钮状态（Button / OptionButton 共用）。
func _set_button_theme(th: Theme, type: String, surface: Color, border: Color, accent: Color, tint: Color, on_accent: Color, fg: Color, dim: Color) -> void:
	th.set_stylebox("normal", type, _box(surface, border, 6, 1, 10, 4))
	th.set_stylebox("hover", type, _box(tint, accent, 6, 1, 10, 4))
	th.set_stylebox("pressed", type, _box(accent, accent, 6, 1, 10, 4))
	th.set_stylebox("disabled", type, _box(surface, border, 6, 1, 10, 4))
	th.set_stylebox("focus", type, _box(Color(0, 0, 0, 0), accent, 6, 2, 10, 4))
	th.set_color("font_color", type, fg)
	th.set_color("font_hover_color", type, accent)
	th.set_color("font_pressed_color", type, on_accent)
	th.set_color("font_disabled_color", type, dim)


## 统一的 StyleBoxFlat：底色 / 边框 / 圆角 / 边框宽 / 左右内边距 / 上下内边距。
func _box(bg_color: Color, border_color: Color, radius: int, border_w: int, pad_h: int, pad_v: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg_color
	box.border_color = border_color
	box.set_border_width_all(border_w)
	box.set_corner_radius_all(radius)
	box.content_margin_left = pad_h
	box.content_margin_right = pad_h
	box.content_margin_top = pad_v
	box.content_margin_bottom = pad_v
	return box


## 页签专用：只有上圆角，选中时画一条强调色下划线。
func _tab_box(bg_color: Color, line_color: Color) -> StyleBoxFlat:
	var box := _box(bg_color, Color(0, 0, 0, 0), 0, 0, 14, 6)
	box.corner_radius_top_left = 5
	box.corner_radius_top_right = 5
	if line_color.a > 0.0:
		box.border_width_bottom = 2
		box.border_color = line_color
	return box


# ---------------------------------------------------------------- 字号

func _load_font_setting() -> void:
	var value: Variant = FONT_DEFAULT
	if Engine.is_editor_hint():
		# EditorSettings 不是全局单例，只能通过 EditorInterface 拿实例
		# （直接写 EditorSettings.has_setting() 会报 “Cannot call non-static function”）
		var settings: EditorSettings = EditorInterface.get_editor_settings()
		if settings != null and settings.has_setting(SETTING_FONT):
			value = settings.get_setting(SETTING_FONT)
	if typeof(value) == TYPE_INT:
		_font_size = _clamp_font(int(value))
	else:
		_font_size = FONT_DEFAULT


func _clamp_font(size: int) -> int:
	if size < FONT_MIN:
		return FONT_MIN
	if size > FONT_MAX:
		return FONT_MAX
	return size


func _apply_font(size: int) -> void:
	_font_size = _clamp_font(size)
	theme = _make_theme(_font_size)
	if _title_label != null:
		_title_label.add_theme_font_size_override("font_size", _font_size + 5)
		_title_label.add_theme_color_override("font_color", _accent_color)
	if _subtitle_label != null:
		_subtitle_label.add_theme_font_size_override("font_size", _font_size - 3)
		_subtitle_label.add_theme_color_override("font_color", _dim_color)
	if _status != null:
		_status.add_theme_font_size_override("font_size", _font_size - 3)
		_status.add_theme_color_override("font_color", _dim_color)
	if _font_label != null:
		_font_label.text = str(_font_size)
	_apply_theme_to_popups()
	if Engine.is_editor_hint():
		var settings: EditorSettings = EditorInterface.get_editor_settings()
		if settings != null:
			settings.set_setting(SETTING_FONT, _font_size)


func _font_smaller() -> void:
	_apply_font(_font_size - 1)


## 下拉浮层（OptionButton / MenuButton 的 popup）是独立 Window，不保证继承面板主题，
## 这里显式挂一份，保证菜单项的底色和悬停高亮跟主界面一致。
func _apply_theme_to_popups() -> void:
	for ob in [_table_pick, _format_pick]:
		if ob != null and is_instance_valid(ob):
			ob.get_popup().theme = theme
	if _import_menu != null and is_instance_valid(_import_menu):
		_import_menu.get_popup().theme = theme


func _font_bigger() -> void:
	_apply_font(_font_size + 1)


# ---------------------------------------------------------------- 浮窗 / 侧边栏

## 切换按钮的文案跟着当前模式走（模式本身由 plugin.gd 持有）。
func refresh_mode_button() -> void:
	if _mode_btn == null:
		return
	var mode := "window"
	if host != null and is_instance_valid(host) and host.has_method("get_mode"):
		mode = str(host.call("get_mode"))
	if mode == "dock":
		_mode_btn.text = "⇱ 弹出浮窗"
		_mode_btn.tooltip_text = "把面板从侧边栏搬到独立窗口"
	else:
		_mode_btn.text = "⇲ 停靠侧边栏"
		_mode_btn.tooltip_text = "把面板停靠到编辑器右侧边栏"


## 延迟一帧再搬家：当前正处在按钮的 pressed 信号里，立刻 reparent 会把发信号的控件摘掉。
func _on_toggle_mode() -> void:
	if host == null or not is_instance_valid(host):
		return
	var mode := "window"
	if host.has_method("get_mode"):
		mode = str(host.call("get_mode"))
	var target := "dock"
	if mode == "window":
		target = "dock"
	else:
		target = "window"
	if host.has_method("set_mode"):
		host.call_deferred("set_mode", target)


# ---------------------------------------------------------------- 页签

func _build_tables_page() -> void:
	var page := VBoxContainer.new()
	page.name = "表数据"
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab.add_child(page)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	page.add_child(bar)
	bar.add_child(_dim_label("表"))
	_table_pick = OptionButton.new()
	_table_pick.custom_minimum_size = Vector2(210, 0)
	_table_pick.item_selected.connect(_on_table_selected)
	bar.add_child(_table_pick)

	_search = LineEdit.new()
	_search.placeholder_text = "搜索（任意列包含即显示）"
	_search.clear_button_enabled = true
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_search.text_changed.connect(_on_search_changed)
	bar.add_child(_search)

	_table_info = Label.new()
	_table_info.add_theme_color_override("font_color", _dim_color)
	bar.add_child(_table_info)

	var ops := HBoxContainer.new()
	ops.add_theme_constant_override("separation", 8)
	page.add_child(ops)
	ops.add_child(_dim_label("导入导出格式"))
	_format_pick = OptionButton.new()
	_format_pick.add_item("CSV", 0)
	_format_pick.add_item("JSON", 1)
	# 默认 JSON：数据源、生成物、导入导出全部以 JSON 为主，CSV 保留为可选
	_format_pick.select(1)
	_format_pick.tooltip_text = "「导入」「导出」默认用这个格式；文件名后缀会覆盖它"
	ops.add_child(_format_pick)
	var import_btn := MenuButton.new()
	import_btn.text = "导入…"
	import_btn.focus_mode = Control.FOCUS_NONE
	# flat=true 时按钮不画 stylebox，看起来就像一段裸文字，这里明确关掉
	import_btn.flat = false
	import_btn.tooltip_text = "导入外部 JSON / CSV：可选「替换全部」或「追加到末尾」"
	import_btn.get_popup().add_item("替换全部（选文件…）", 0)
	import_btn.get_popup().add_item("追加到末尾（选文件…）", 1)
	import_btn.get_popup().add_item("从路径替换…", 2)
	import_btn.get_popup().add_item("从路径追加…", 3)
	import_btn.get_popup().id_pressed.connect(_on_import_menu)
	ops.add_child(import_btn)
	_import_menu = import_btn
	# 下拉菜单是独立 Window，不一定继承面板主题，这里显式挂一份
	import_btn.get_popup().theme = theme
	_add_button(ops, "导出…", Callable(self, "_on_export"))
	ops.add_child(VSeparator.new())
	var btn_add_row := _add_button(ops, "新增行", Callable(self, "_on_add_row"))
	btn_add_row.tooltip_text = "在表末尾追加一行（先写内存，点「保存表」才写回源文件）"
	var btn_del_row := _add_button(ops, "删除行", Callable(self, "_on_delete_row"))
	btn_del_row.tooltip_text = "删除表格里选中的那一行（先写内存，点「保存表」才写回源文件）"
	_add_button(ops, "保存表", Callable(self, "_on_save_table"))

	_grid = Tree.new()
	_grid.hide_root = true
	_grid.select_mode = Tree.SELECT_ROW
	_grid.column_titles_visible = true
	_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_grid.item_edited.connect(_on_cell_edited)
	# 双击直接进入编辑（Godot 默认的双击不一定会进编辑态，常常只是又选中一次）
	_grid.item_activated.connect(_on_grid_activated)
	page.add_child(_grid)
	_apply_theme_to_popups()


func _build_schema_page() -> void:
	var page := VBoxContainer.new()
	page.name = "结构"
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab.add_child(page)

	# 第一行：筛选 + 计数（与「表数据」页第一行同样的骨架，视线不用来回跳）
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	page.add_child(bar)
	bar.add_child(_dim_label("筛选"))
	_schema_search = LineEdit.new()
	_schema_search.placeholder_text = "筛选（结构 / 枚举 / 表名或字段名包含即显示）"
	_schema_search.clear_button_enabled = true
	_schema_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_schema_search.text_changed.connect(_on_schema_search_changed)
	bar.add_child(_schema_search)
	_schema_count = Label.new()
	_schema_count.add_theme_color_override("font_color", _dim_color)
	bar.add_child(_schema_count)

	# 第二行：操作（与「表数据」页第二行同样位置）
	var ops := HBoxContainer.new()
	ops.add_theme_constant_override("separation", 8)
	page.add_child(ops)
	var btn_save := _add_button(ops, "保存结构", Callable(self, "_on_save_schema"))
	btn_save.tooltip_text = "把结构页的改动写回 configforge/schema.json，并重新加载数据"
	var btn_props := _add_button(ops, "字段属性…", Callable(self, "_open_field_properties"))
	btn_props.tooltip_text = "选中字段行后打开弹窗，改类型 / min~max / 长度 / ref / sep / 正则 / 资源路径"
	ops.add_child(VSeparator.new())
	var btn_add_field := _add_button(ops, "新增字段", Callable(self, "_on_add_field"))
	btn_add_field.tooltip_text = "给选中的结构（没选就用当前表的结构）加一个 int 字段"
	var btn_del_field := _add_button(ops, "删除字段", Callable(self, "_on_delete_field"))
	btn_del_field.tooltip_text = "删除结构页里选中的那个字段行"
	ops.add_child(VSeparator.new())
	var btn_add_enum := _add_button(ops, "新增枚举", Callable(self, "_on_add_enum"))
	btn_add_enum.tooltip_text = "新建一个枚举（默认带 Common = 1），可双击改取值"
	var btn_del_enum := _add_button(ops, "删除枚举", Callable(self, "_on_delete_enum"))
	btn_del_enum.tooltip_text = "删除选中的枚举（被字段引用时会拒绝）"
	ops.add_child(VSeparator.new())
	var btn_add_table := _add_button(ops, "新增表", Callable(self, "_on_add_table"))
	btn_add_table.tooltip_text = "用选中的结构新建一张表，并生成空的数据源文件"
	var btn_del_table := _add_button(ops, "删除表", Callable(self, "_on_delete_table"))
	btn_del_table.tooltip_text = "删除选中的表（被字段 ref 引用时会拒绝，数据文件保留）"

	_schema_tree = Tree.new()
	_schema_tree.hide_root = true
	_schema_tree.column_titles_visible = true
	# 整行选中：点任意一列都选到这一行，而不是只有第一列可点
	_schema_tree.select_mode = Tree.SELECT_ROW
	_schema_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_schema_tree.item_edited.connect(_on_schema_edited)
	# 双击直接进入编辑（类型 / 名称 / 分组 / 说明 / 枚举取值都能改）
	_schema_tree.item_activated.connect(_on_schema_activated)
	page.add_child(_schema_tree)


# ---------------------------------------------------------------- 字段属性弹窗

## 「字段属性」弹窗：类型 / min~max / 长度 / ref / sep / 正则 / 资源路径。
## 点工具条上的「字段属性…」打开（选中字段行才可用）。
func _build_field_dialog() -> Window:
	var win := Window.new()
	win.title = "字段属性"
	win.size = Vector2i(700, 330)
	win.min_size = Vector2i(600, 300)
	win.exclusive = false
	win.wrap_controls = false
	win.visible = false
	win.close_requested.connect(_close_field_dialog)

	var root := VBoxContainer.new()
	root.add_theme_constant_override("separation", 8)
	win.add_child(root)

	_fx_title = Label.new()
	_fx_title.add_theme_color_override("font_color", _accent_color)
	root.add_child(_fx_title)

	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 6)
	root.add_child(grid)

	_fx_type = LineEdit.new()
	_fx_type.custom_minimum_size = Vector2(140, 0)
	_fx_type.tooltip_text = "int / string / bool / float / 枚举名 / list,xxx / map,k,v / 结构名"
	grid.add_child(_dim_label("类型"))
	grid.add_child(_fx_type)

	_fx_min = _small_edit(64)
	_fx_max = _small_edit(64)
	var minmax := HBoxContainer.new()
	minmax.add_theme_constant_override("separation", 2)
	minmax.add_child(_fx_min)
	minmax.add_child(_dim_label("~"))
	minmax.add_child(_fx_max)
	grid.add_child(_dim_label("min / max"))
	grid.add_child(minmax)

	_fx_len_min = _small_edit(56)
	_fx_len_max = _small_edit(56)
	var len_box := HBoxContainer.new()
	len_box.add_theme_constant_override("separation", 2)
	len_box.add_child(_fx_len_min)
	len_box.add_child(_dim_label("~"))
	len_box.add_child(_fx_len_max)
	grid.add_child(_dim_label("长度"))
	grid.add_child(len_box)

	_fx_ref = OptionButton.new()
	_fx_ref.custom_minimum_size = Vector2(140, 0)
	_fx_ref.tooltip_text = "ref：这个字段填的是哪张表的主键"
	grid.add_child(_dim_label("ref"))
	grid.add_child(_fx_ref)

	_fx_sep = _small_edit(64)
	_fx_sep.tooltip_text = "list / map 用哪个分隔符拆，默认 |"
	grid.add_child(_dim_label("sep"))
	grid.add_child(_fx_sep)

	_fx_pattern = LineEdit.new()
	_fx_pattern.custom_minimum_size = Vector2(140, 0)
	_fx_pattern.tooltip_text = "正则约束（string 才有意义）"
	grid.add_child(_dim_label("正则"))
	grid.add_child(_fx_pattern)

	_fx_path = LineEdit.new()
	_fx_path.custom_minimum_size = Vector2(300, 0)
	_fx_path.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_fx_path.placeholder_text = "res://assets/icons/sword.svg"
	_fx_path.tooltip_text = "资源路径约束（填了就要求文件真实存在）"
	grid.add_child(_dim_label("资源"))
	grid.add_child(_fx_path)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 8)
	root.add_child(buttons)
	var apply := _add_button(buttons, "应用", Callable(self, "_on_apply_field_constraints"))
	apply.tooltip_text = "把上面这些写回字段定义（未保存，仍需点「保存结构」）"
	_add_button(buttons, "清空约束", Callable(self, "_on_clear_field_constraints"))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)
	_add_button(buttons, "关闭", Callable(self, "_close_field_dialog"))
	return win


func _close_field_dialog() -> void:
	if _field_dialog != null:
		_field_dialog.hide()


## 打开弹窗：只对字段行有效。
func _open_field_properties() -> void:
	var meta := _selected_field_meta()
	if meta.is_empty():
		_set_status("先在结构树里选中一个字段行，再点「字段属性…」")
		_log("请先在结构树里选中一个字段行", COLOR_WARN)
		return
	if _field_dialog == null:
		_field_dialog = _build_field_dialog()
		add_child(_field_dialog)
	# Window 是独立 Viewport，不继承面板的 theme，这里手动挂上（字号/选中态才一致）
	_field_dialog.theme = theme
	_fill_field_dialog(meta)
	_field_dialog.popup_centered()


## 把某个字段的 raw 定义回填到弹窗控件里。
func _fill_field_dialog(meta: Dictionary) -> void:
	var bean_name := str(meta.get("bean", ""))
	var idx := int(meta.get("index", -1))
	var raw_bean := _pipeline.schema.raw_bean(bean_name)
	var raw_fields: Array = raw_bean.get("fields", [])
	if idx < 0 or idx >= raw_fields.size():
		return
	var rf: Dictionary = raw_fields[idx]
	_fx_bean = bean_name
	_fx_index = idx
	_fx_name = str(rf.get("name", ""))
	_fx_title.text = "%s.%s" % [bean_name, _fx_name]
	_fx_type.text = str(rf.get("type", ""))
	_fx_min.text = _to_text(rf.get("min", null))
	_fx_max.text = _to_text(rf.get("max", null))
	_fx_len_min.text = _to_text(rf.get("len_min", null))
	_fx_len_max.text = _to_text(rf.get("len_max", null))
	if not rf.has("len_min") and rf.has("len"):
		var lv: Variant = rf["len"]
		if lv is Array:
			if lv.size() >= 1:
				_fx_len_min.text = _to_text(lv[0])
			if lv.size() >= 2:
				_fx_len_max.text = _to_text(lv[1])
		else:
			_fx_len_min.text = _to_text(lv)
			_fx_len_max.text = _to_text(lv)
	_fx_sep.text = str(rf.get("sep", ""))
	_fx_pattern.text = str(rf.get("pattern", ""))
	_fx_path.text = str(rf.get("path", ""))
	_fill_ref_options(str(rf.get("ref", "")))


func _small_edit(width: int) -> LineEdit:
	var edit := LineEdit.new()
	edit.custom_minimum_size = Vector2(width, 0)
	return edit


func _selected_field_meta() -> Dictionary:
	if _schema_tree == null:
		return {}
	var item := _schema_tree.get_selected()
	if item == null:
		return {}
	var meta: Variant = item.get_metadata(0)
	if not (meta is Dictionary) or str(meta.get("kind", "")) != "field":
		return {}
	return meta


func _fill_ref_options(current: String) -> void:
	if _fx_ref == null:
		return
	_fx_ref.clear()
	_fx_ref.add_item("(无)")
	var pick := 0
	var i := 1
	for t in _pipeline.schema.tables:
		var tn := str(t["name"])
		_fx_ref.add_item(tn)
		if tn == current:
			pick = i
		i += 1
	_fx_ref.select(pick)


func _on_apply_field_constraints() -> void:
	if _fx_index < 0:
		_set_status("先在结构树里选中一个字段行")
		return
	var raw_bean := _pipeline.schema.raw_bean(_fx_bean)
	var raw_fields: Array = raw_bean.get("fields", [])
	if _fx_index < 0 or _fx_index >= raw_fields.size():
		return
	var rf: Dictionary = raw_fields[_fx_index]
	var ftype := _fx_type.text.strip_edges()
	if ftype == "":
		_set_status("类型不能为空")
		return
	rf["type"] = ftype
	var err := _set_number(rf, "min", _fx_min.text)
	if err == "":
		err = _set_number(rf, "max", _fx_max.text)
	if err == "":
		err = _set_int(rf, "len_min", _fx_len_min.text)
	if err == "":
		err = _set_int(rf, "len_max", _fx_len_max.text)
	if err != "":
		_set_status(err)
		_log(err, COLOR_ERR)
		return
	rf.erase("len")
	_set_text(rf, "sep", _fx_sep.text)
	_set_text(rf, "pattern", _fx_pattern.text)
	_set_text(rf, "path", _fx_path.text)
	var ref_sel := ""
	if _fx_ref.selected > 0:
		ref_sel = _fx_ref.get_item_text(_fx_ref.selected)
	if ref_sel == "":
		rf.erase("ref")
	else:
		rf["ref"] = ref_sel
	var fname := str(rf.get("name", ""))
	_schema_edits += 1
	_pipeline.schema.reparse()
	_refresh_schema_tree()
	_refresh_grid()
	_reveal_field(_fx_bean, fname)
	var meta_now := _selected_field_meta()
	if not meta_now.is_empty():
		_fill_field_dialog(meta_now)
	_set_status("字段 %s.%s 的属性已更新（未保存，点「保存结构」写回）" % [_fx_bean, fname], COLOR_WARN)
	_log("字段 %s.%s 的属性已改（未保存）" % [_fx_bean, fname], COLOR_WARN)


func _on_clear_field_constraints() -> void:
	if _fx_index < 0:
		_set_status("先在结构树里选中一个字段行")
		return
	var raw_bean := _pipeline.schema.raw_bean(_fx_bean)
	var raw_fields: Array = raw_bean.get("fields", [])
	if _fx_index < 0 or _fx_index >= raw_fields.size():
		return
	var rf: Dictionary = raw_fields[_fx_index]
	for key in ["min", "max", "len", "len_min", "len_max", "pattern", "path", "ref", "sep"]:
		rf.erase(key)
	_fx_min.text = ""
	_fx_max.text = ""
	_fx_len_min.text = ""
	_fx_len_max.text = ""
	_fx_sep.text = ""
	_fx_pattern.text = ""
	_fx_path.text = ""
	_fx_ref.select(0)
	_on_apply_field_constraints()


## 空串 → 删掉该键；整数/小数 → 写入；其它 → 返回错误提示。
func _set_number(target: Dictionary, key: String, text: String) -> String:
	var t := text.strip_edges()
	if t == "":
		target.erase(key)
		return ""
	if t.is_valid_int():
		target[key] = int(t)
		return ""
	if t.is_valid_float():
		target[key] = float(t)
		return ""
	return "%s 必须是数字：%s" % [key, t]


func _set_int(target: Dictionary, key: String, text: String) -> String:
	var t := text.strip_edges()
	if t == "":
		target.erase(key)
		return ""
	if not t.is_valid_int():
		return "%s 必须是整数：%s" % [key, t]
	target[key] = int(t)
	return ""


func _set_text(target: Dictionary, key: String, text: String) -> void:
	var t := text.strip_edges()
	if t == "":
		target.erase(key)
		return
	target[key] = t


func _build_issues_page() -> void:
	var page := VBoxContainer.new()
	page.name = "校验结果"
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab.add_child(page)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	page.add_child(bar)
	_add_button(bar, "清空结果", Callable(self, "_on_clear_issues"))
	bar.add_child(VSeparator.new())
	bar.add_child(_dim_label("双击一条问题可跳到对应表与行；error 会阻止生成，warning 不会"))

	_issue_tree = Tree.new()
	_issue_tree.hide_root = true
	_issue_tree.column_titles_visible = true
	_issue_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_issue_tree.item_activated.connect(_on_issue_activated)
	page.add_child(_issue_tree)


func _build_log_page() -> void:
	var page := VBoxContainer.new()
	page.name = "日志"
	page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tab.add_child(page)

	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	page.add_child(bar)
	_add_button(bar, "清空日志", Callable(self, "_on_clear_log"))
	bar.add_child(VSeparator.new())
	bar.add_child(_dim_label("加载 / 编辑 / 联动 / 导入导出 / 生成全过程"))

	_log_view = RichTextLabel.new()
	_log_view.bbcode_enabled = true
	_log_view.scroll_following = true
	_log_view.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log_view.custom_minimum_size = Vector2(0, 120)
	page.add_child(_log_view)


# ---------------------------------------------------------------- 重新加载

func reload_all() -> void:
	_clear_log()
	var discarded := _schema_edits
	_schema_edits = 0
	_log("配置工坊 v%s · 结构文件 %s" % [VERSION, _pipeline.schema_path], COLOR_ACCENT)
	if discarded > 0:
		_log("已放弃 %d 处未保存的结构改动（以磁盘上的 schema.json 为准）" % discarded, COLOR_WARN)

	var ok := _pipeline.load_schema()
	_rebuild_picker()
	if not ok:
		_log("结构解析失败：%d 个错误" % _pipeline.schema.error_count(), COLOR_ERR)
		_show_issues(_pipeline.schema.issues)
		_refresh_schema_tree()
		_clear_grid()
		_set_status("结构解析失败，请先修 schema.json")
		if _tab != null:
			_tab.current_tab = TAB_ISSUES
		return

	_log("结构：%d 个枚举 / %d 个结构 / %d 张表" % [
		_pipeline.schema.enums.size(),
		_pipeline.schema.beans.size(),
		_pipeline.schema.tables.size()], COLOR_DIM)

	if not _pipeline.load_data():
		_log("数据加载存在错误（坏值已保留占位，可直接在表格里修）", COLOR_ERR)

	_pipeline.validate()
	_show_issues(_pipeline.issues)
	_refresh_schema_tree()
	_refresh_grid()
	_update_status()

	var errors := CFIssue.count_errors(_pipeline.issues)
	if errors == 0:
		_log("校验通过，无错误", COLOR_OK)
	else:
		_log("校验发现 %d 个错误、%d 个警告" % [errors, CFIssue.count_warnings(_pipeline.issues)], COLOR_WARN)


func _rebuild_picker() -> void:
	if _table_pick == null:
		return
	var keep := _current_table
	_table_pick.clear()
	for t in _pipeline.schema.tables:
		var idx := _table_pick.item_count
		_table_pick.add_item(str(t["name"]))
		_table_pick.set_item_metadata(idx, str(t["name"]))
	_table_pick.disabled = _table_pick.item_count == 0
	if keep != "" and _select_picker(keep):
		return
	if _table_pick.item_count > 0:
		_table_pick.select(0)
		_current_table = str(_table_pick.get_item_metadata(0))
	else:
		_current_table = ""


func _select_picker(table_name: String) -> bool:
	if _table_pick == null:
		return false
	for i in range(_table_pick.item_count):
		if str(_table_pick.get_item_metadata(i)) == table_name:
			_table_pick.select(i)
			_current_table = table_name
			return true
	return false


func _on_table_selected(index: int) -> void:
	if _table_pick == null:
		return
	if index < 0 or index >= _table_pick.item_count:
		return
	_current_table = str(_table_pick.get_item_metadata(index))
	_refresh_grid()


func _on_search_changed(_text: String) -> void:
	_refresh_grid()


# ---------------------------------------------------------------- 表格

func _clear_grid() -> void:
	if _grid == null:
		return
	_cancel_cell_edit()
	_grid.clear()
	_grid.columns = 1
	_grid_fields = []
	if _table_info != null:
		_table_info.text = ""


func _refresh_grid() -> void:
	if _grid == null:
		return
	# 不再用 if _syncing: return 当入口守卫：万一某次刷新中途报错，标志会永远卡在 true，
	# 之后所有刷新都会静默失效（表现就是"导入/新增了数据但表格不更新"）。
	_syncing = true
	_cancel_cell_edit()
	_grid.clear()
	_grid_fields = []
	_ref_cache.clear()

	var table := _pipeline.schema.table_by_name(_current_table)
	if table.is_empty():
		_grid.columns = 1
		if _table_info != null:
			_table_info.text = ""
		_syncing = false
		return

	var fields: Array = table["bean"]["fields"]
	_grid_fields = fields
	_grid.columns = fields.size() + 1
	_grid.set_column_title(0, "#")
	_grid.set_column_expand(0, false)
	_grid.set_column_custom_minimum_width(0, 50)
	for i in range(fields.size()):
		var f: Dictionary = fields[i]
		_grid.set_column_title(i + 1, str(f["name"]))
		_grid.set_column_expand(i + 1, true)
		_grid.set_column_custom_minimum_width(i + 1, 110)

	var loaded: Dictionary = _pipeline.tables.get(_current_table, {})
	var records: Array = loaded.get("records", [])
	var filter := ""
	if _search != null:
		filter = _search.text.strip_edges().to_lower()

	# 必须显式建隐藏根：Tree.create_item() 不给 parent 时第一次调用建的是「根节点」本身，
	# 而 hide_root=true 会把它隐藏 —— 结果第一条记录永远不显示。
	var root := _grid.create_item()
	var shown := 0
	for r in range(records.size()):
		var rec: Dictionary = records[r]
		if filter != "" and not _record_matches(rec, fields, filter):
			continue
		var item := _grid.create_item(root)
		item.set_text(0, str(r + 1))
		item.set_metadata(0, r)
		item.set_selectable(0, true)
		for i in range(fields.size()):
			var f: Dictionary = fields[i]
			var col := i + 1
			var value: Variant = rec.get(str(f["name"]), null)
			item.set_text(col, _display_value(f, value))
			# 不用 Tree 内置编辑（它「同一格再单击一次就进编辑」），双击由我们的编辑器接管
			item.set_tooltip_text(col, _field_tooltip(f))
		shown += 1

	if _table_info != null:
		# 只显示条数；数据源文件名（item.csv 之类）放进 tooltip，不在界面上露后缀
		_table_info.text = "%d / %d 条" % [shown, records.size()]
		_table_info.tooltip_text = "数据源：%s" % str(table["file_name"])
	_syncing = false


func _record_matches(rec: Dictionary, fields: Array, filter: String) -> bool:
	for f in fields:
		var value: Variant = rec.get(str(f["name"]), null)
		if _to_text(value).to_lower().find(filter) >= 0:
			return true
	return false


func _to_text(value: Variant) -> String:
	if value == null:
		return ""
	if value is bool:
		if value:
			return "true"
		return "false"
	if value is float:
		if float(value) == float(int(value)):
			return str(int(value))
		return str(value)
	return str(value)


## 表里的值 → 单元格文本（ref 显示「id 名称」、枚举显示取值名、list/map 用 sep 拼）。
func _display_value(field: Dictionary, value: Variant) -> String:
	if value == null:
		return ""
	var ref := str(field["ref"])
	if ref != "" and not (value is Array) and not (value is Dictionary):
		var target_name := _name_of_ref(ref, value)
		if target_name != "":
			return "%s %s" % [_to_text(value), target_name]
	var kind := str(field["kind"])
	if kind == "list":
		if value is Array:
			return _join_cells(str(field["sep"]), value)
		return str(value)
	if kind == "map":
		if value is Dictionary:
			var pairs: Array = []
			for k in value.keys():
				pairs.append("%s:%s" % [_to_text(k), _to_text(value[k])])
			return _join_cells(str(field["sep"]), pairs)
		return str(value)
	if kind == "bean":
		return JSON.stringify(value, "", false)
	if kind == "enum":
		var info: Dictionary = field["info"]
		var name := _pipeline.schema.enum_name_of(str(info.get("type", "")), value)
		if name != "":
			return name
		return _to_text(value)
	return _to_text(value)


func _join_cells(sep: String, parts: Array) -> String:
	var packed := PackedStringArray()
	for p in parts:
		packed.append(str(p))
	return sep.join(packed)


func _field_tooltip(field: Dictionary) -> String:
	var parts: Array = [str(field["type"])]
	if str(field["ref"]) != "":
		parts.append("ref→" + str(field["ref"]))
	if str(field["comment"]) != "":
		parts.append(str(field["comment"]))
	var kind := str(field["kind"])
	if kind == "enum":
		parts.append("可填取值名、别名或数值")
	if kind == "list" or kind == "map":
		parts.append("用 %s 分隔" % str(field["sep"]))
	if str(field["ref"]) != "":
		parts.append("可填 id / 名称 / 「id 名称」")
	return " · ".join(PackedStringArray(parts))


## 引用值 → 目标表记录的名称（带缓存）。
func _name_of_ref(ref_table: String, value: Variant) -> String:
	var key := "%s|%s" % [ref_table, _to_text(value)]
	if _ref_cache.has(key):
		return str(_ref_cache[key])
	var out := ""
	var target := _pipeline.schema.table_by_name(ref_table)
	if not target.is_empty():
		var index := _pipeline.schema.index_field(target)
		if not index.is_empty():
			var loaded: Dictionary = _pipeline.tables.get(ref_table, {})
			var records: Array = loaded.get("records", [])
			var id_field := str(index["name"])
			for rec in records:
				if rec is Dictionary and rec.get(id_field, null) == value:
					out = str(rec.get("name", ""))
					break
	_ref_cache[key] = out
	return out


func _clear_cell_issues(table_name: String, row: int, field_name: String) -> void:
	var loaded: Dictionary = _pipeline.tables.get(table_name, {})
	var issues: Array = loaded.get("issues", [])
	if issues.is_empty():
		return
	var kept: Array = []
	for it in issues:
		if not (it is Dictionary):
			continue
		var same_row := str(it.get("table", "")) == table_name and int(it.get("row", 0)) == row
		var it_field := str(it.get("field", ""))
		if same_row and (it_field == field_name or it_field.begins_with(field_name + "[")):
			continue
		kept.append(it)
	loaded["issues"] = kept


## 双击表格单元格 → 打开内嵌输入框（单击只选中，不进编辑）。
func _on_grid_activated() -> void:
	_begin_edit_at_selected(_grid)


# ---------------------------------------------------------------- 双击编辑

## 每个 Tree 一个内嵌输入框（复用，避免频繁创建）。
func _editor_for(tree: Tree) -> LineEdit:
	if _cell_editors.has(tree) and is_instance_valid(_cell_editors[tree]):
		return _cell_editors[tree]
	var edit := LineEdit.new()
	edit.visible = false
	edit.text_submitted.connect(_on_cell_edit_submitted.bind(tree))
	edit.focus_exited.connect(_on_cell_edit_focus_exited.bind(tree))
	edit.gui_input.connect(_on_cell_edit_gui_input.bind(tree))
	tree.add_child(edit)
	_cell_editors[tree] = edit
	return edit


## 双击 / 回车 → 在当前单元格上叠一个输入框。
## 用鼠标位置定位（SELECT_ROW 模式下 get_selected_column() 不一定跟着走）。
func _begin_edit_at_selected(tree: Tree) -> void:
	if tree == null:
		return
	# 先提交上一个编辑：它可能触发重建（reparse + 刷新树），item 会失效，
	# 所以要在提交之后再按鼠标位置重新取 item
	_commit_cell_edit()
	var pos := tree.get_local_mouse_position()
	var item := tree.get_item_at_position(pos)
	var col := tree.get_column_at_position(pos)
	if item == null:
		item = tree.get_selected()
		col = tree.get_selected_column()
	if item == null or col < 0:
		return
	if not _cell_is_editable(tree, item, col):
		return
	_begin_cell_edit(tree, item, col)


func _begin_cell_edit(tree: Tree, item: TreeItem, col: int) -> void:
	var edit := _editor_for(tree)
	var rect := tree.get_item_area_rect(item, col)
	_edit_tree = tree
	_edit_item = item
	_edit_col = col
	edit.text = item.get_text(col)
	edit.position = rect.position
	edit.size = Vector2(maxf(rect.size.x, 90.0), maxf(rect.size.y, 22.0))
	edit.visible = true
	edit.grab_focus()
	edit.select_all()


## 该节点该列是否可编辑（决定双击进不进编辑）。
func _cell_is_editable(tree: Tree, item: TreeItem, col: int) -> bool:
	if col < 0:
		return false
	if tree == _grid:
		if col < 1 or col > _grid_fields.size():
			return false
		return str(_grid_fields[col - 1]["kind"]) != "bean"
	if tree != _schema_tree:
		return false
	var meta: Variant = item.get_metadata(0)
	if not (meta is Dictionary):
		return false
	var kind := str(meta.get("kind", ""))
	if kind == "field":
		return col == 0 or col == 1
	if kind == "enum":
		return col == 0 or col == 3
	if kind == "enum_value":
		return col == 0 or col == 1
	if kind == "table":
		return col == 0 or col == 2 or col == 3
	if kind == "bean":
		return col == 3
	return false


func _on_cell_edit_submitted(_text: String, _tree: Tree) -> void:
	_commit_cell_edit()


func _on_cell_edit_focus_exited(_tree: Tree) -> void:
	# 焦点移走也算提交（点别处、切页签都会走这里）
	_commit_cell_edit()


func _on_cell_edit_gui_input(event: InputEvent, tree: Tree) -> void:
	if event is InputEventKey:
		var key: InputEventKey = event
		if key.pressed and key.keycode == KEY_ESCAPE:
			_cancel_cell_edit()
			tree.accept_event()


## 提交：先把文本写回单元格，再走既有的提交逻辑。
func _commit_cell_edit() -> void:
	if _edit_tree == null or _edit_item == null or _edit_col < 0:
		return
	var tree := _edit_tree
	var item := _edit_item
	var col := _edit_col
	_edit_tree = null
	_edit_item = null
	_edit_col = -1
	var edit: LineEdit = _cell_editors.get(tree)
	if edit == null or not is_instance_valid(edit):
		return
	var text := edit.text
	edit.visible = false
	if text == item.get_text(col):
		return
	item.set_text(col, text)
	if tree == _grid:
		_on_cell_edited(item, col)
	else:
		_on_schema_edited(item, col)


func _cancel_cell_edit() -> void:
	if _edit_tree == null:
		return
	var tree := _edit_tree
	# 先把状态清掉：下面 hide() 会触发 focus_exited，不清会被当成「提交」
	_edit_tree = null
	_edit_item = null
	_edit_col = -1
	var edit: LineEdit = _cell_editors.get(tree)
	if edit != null and is_instance_valid(edit):
		edit.visible = false


func _on_cell_edited(item: TreeItem = null, col: int = -1) -> void:
	if _syncing or _grid == null:
		return
	if item == null:
		item = _grid.get_edited()
		col = _grid.get_edited_column()
	if item == null or col <= 0 or col > _grid_fields.size():
		return
	var row := int(item.get_metadata(0))
	var table := _pipeline.schema.table_by_name(_current_table)
	if table.is_empty():
		return
	var loaded: Dictionary = _pipeline.tables.get(_current_table, {})
	var records: Array = loaded.get("records", [])
	if row < 0 or row >= records.size():
		return
	var rec: Dictionary = records[row]
	var field: Dictionary = _grid_fields[col - 1]
	var fname := str(field["name"])
	var ctx := {
		"table": _current_table,
		"row": row + 1,
		"field": fname,
		"file": str(loaded.get("file", ""))
	}
	var parsed := _parse_cell(field, item.get_text(col), ctx)
	if not bool(parsed["ok"]):
		item.set_text(col, _display_value(field, rec.get(fname, null)))
		var issue: Variant = parsed["issue"]
		if issue is Dictionary:
			_log(CFIssue.format(issue), COLOR_ERR)
		_set_status("单元格修改被拒绝：%s" % fname, COLOR_ERR)
		return

	var old_value: Variant = rec.get(fname, null)
	var new_value: Variant = parsed["value"]
	rec[fname] = new_value
	_ref_cache.clear()
	_clear_cell_issues(_current_table, row + 1, fname)
	item.set_text(col, _display_value(field, new_value))

	if old_value != new_value:
		_log("修改 [%s] 第 %d 条 %s：%s → %s" % [
			_current_table, row + 1, fname, _to_text(old_value), _to_text(new_value)], COLOR_DIM)
		var index_name := str(table.get("index", ""))
		if index_name != "" and fname == index_name and old_value != null:
			var moved := _pipeline.cascade_index(_current_table, old_value, new_value)
			if not moved.is_empty():
				_log("联动更新：%s 的 %s %s → %s，已同步 %d 处引用" % [
					_current_table, index_name, _to_text(old_value), _to_text(new_value), moved.size()], COLOR_OK)
				for m in moved:
					_log("  · [%s] 第 %d 条 %s" % [str(m["table"]), int(m["row"]), str(m["field"])], COLOR_DIM)
				_refresh_grid()

	_pipeline.validate()
	_show_issues(_pipeline.issues)
	_update_status()


## 单元格文本 → 类型化值。带 ref 的标量字段支持「id」「名称」「id 名称」三种写法。
func _parse_cell(field: Dictionary, text: String, ctx: Dictionary) -> Dictionary:
	var ref := str(field["ref"])
	var kind := str(field["kind"])
	if ref == "" or kind == "list" or kind == "map" or kind == "bean":
		return CFDataLoader.convert_value(_pipeline.schema, field, text, ctx)
	var target := _pipeline.schema.table_by_name(ref)
	if target.is_empty():
		return CFDataLoader.convert_value(_pipeline.schema, field, text, ctx)
	var raw := text.strip_edges()
	if raw == "":
		return CFDataLoader.convert_value(_pipeline.schema, field, "", ctx)

	var id_text := raw
	var space := raw.find(" ")
	if space > 0:
		var head := raw.substr(0, space)
		if head.is_valid_int():
			id_text = head
	if id_text.is_valid_int():
		return CFDataLoader.convert_value(_pipeline.schema, field, id_text, ctx)

	var loaded: Dictionary = _pipeline.tables.get(str(target["name"]), {})
	var records: Array = loaded.get("records", [])
	var index_field := _pipeline.schema.index_field(target)
	if index_field.is_empty():
		return CFDataLoader.convert_value(_pipeline.schema, field, raw, ctx)
	var id_name := str(index_field["name"])
	var want := raw
	if space > 0:
		want = raw.substr(space + 1).strip_edges()

	var exact: Array = []
	var fuzzy: Array = []
	for rec in records:
		if not (rec is Dictionary):
			continue
		var rec_name := str(rec.get("name", ""))
		if rec_name == "":
			continue
		if rec_name == want or rec_name == raw:
			exact.append(rec)
		elif rec_name.find(want) >= 0:
			fuzzy.append(rec)

	var hits: Array = exact
	if hits.is_empty():
		hits = fuzzy
	if hits.size() == 1:
		return CFDataLoader.convert_value(_pipeline.schema, field, hits[0].get(id_name, null), ctx)
	if hits.size() > 1:
		var issue := CFIssue.make(CFIssue.ERROR, "E_REF_AMBIGUOUS",
			"字段 %s 的名称匹配到多条记录（请直接填 id）" % str(field["name"]), ctx)
		return {"ok": false, "value": null, "issue": issue}

	var issue2 := CFIssue.make(CFIssue.ERROR, "E_REF_TEXT",
		"字段 %s 无法匹配表 %s 的记录：%s" % [str(field["name"]), ref, raw], ctx)
	return {"ok": false, "value": null, "issue": issue2}


# ---------------------------------------------------------------- 行操作

func _on_add_row() -> void:
	# 纯内存操作，不受「结构有未保存改动」限制
	# （否则点过「新增字段」之后这个按钮就一直没反应）
	var table := _pipeline.schema.table_by_name(_current_table)
	if table.is_empty():
		_log("请先选择一张表", COLOR_WARN)
		_set_status("新增行失败：当前没有选中的表")
		return
	var rec := _pipeline.new_record(_current_table)
	var loaded: Dictionary = _pipeline.tables.get(_current_table, {})
	if not loaded.has("records"):
		loaded["records"] = []
		loaded["lines"] = []
		loaded["issues"] = []
		loaded["file"] = ""
		_pipeline.tables[_current_table] = loaded
	var records: Array = loaded["records"]
	records.append(rec)
	_refresh_grid()
	_pipeline.validate()
	_show_issues(_pipeline.issues)
	_update_status()
	var suffix := ""
	var index_name := str(table.get("index", ""))
	if index_name != "":
		suffix = "（%s = %s）" % [index_name, _to_text(rec.get(index_name, null))]
	_log("已新增一行%s，填好内容后点「保存表」写回源文件" % suffix, COLOR_OK)
	_set_status("已新增一行%s（未保存，点「保存表」写回）" % suffix, COLOR_OK)


func _on_delete_row() -> void:
	if _grid == null:
		return
	var table := _pipeline.schema.table_by_name(_current_table)
	if table.is_empty():
		_log("请先选择一张表", COLOR_WARN)
		return
	var item := _grid.get_selected()
	if item == null:
		_log("请先在表格里选中一行", COLOR_WARN)
		return
	var row := int(item.get_metadata(0))
	var loaded: Dictionary = _pipeline.tables.get(_current_table, {})
	var records: Array = loaded.get("records", [])
	if row < 0 or row >= records.size():
		return
	var rec: Dictionary = records[row]
	var index_name := str(table.get("index", ""))
	if index_name != "":
		var value: Variant = rec.get(index_name, null)
		var refs := _pipeline.references_to(_current_table, value)
		if not refs.is_empty():
			_log("不能删除：%s=%s 仍被 %d 处引用" % [index_name, _to_text(value), refs.size()], COLOR_ERR)
			for r in refs:
				_log("  · [%s] 第 %d 条 %s" % [str(r["table"]), int(r["row"]), str(r["field"])], COLOR_DIM)
			return
	records.remove_at(row)
	_ref_cache.clear()
	_refresh_grid()
	_pipeline.validate()
	_show_issues(_pipeline.issues)
	_update_status()
	_log("已删除 [%s] 第 %d 条（内存中，点「保存表」才写回）" % [_current_table, row + 1], COLOR_WARN)
	_set_status("已删除第 %d 条（未保存，点「保存表」写回）" % (row + 1), COLOR_OK)


## 结构页有未保存改动时，禁止用旧字段模型读写表数据。
func _guard_schema_dirty() -> bool:
	if _schema_edits <= 0:
		return false
	_log("结构有 %d 处未保存的改动：请先在「结构」页点「保存结构」" % _schema_edits, COLOR_ERR)
	_set_status("结构有 %d 处未保存改动，先点「保存结构」再继续（否则数据和结构会对不上）" % _schema_edits, COLOR_ERR)
	if _tab != null:
		_tab.current_tab = TAB_SCHEMA
	return true


func _on_save_table() -> void:
	if _guard_schema_dirty():
		return
	if _current_table == "":
		_log("请先选择一张表", COLOR_WARN)
		return
	var result := _pipeline.save_table(_current_table)
	if bool(result["ok"]):
		_log("已保存 %s（%d 条）→ %s" % [
			_current_table, int(result["count"]), str(result["path"])], COLOR_OK)
		_scan_filesystem()
	else:
		_log("保存失败：" + str(result["error"]), COLOR_ERR)


# ---------------------------------------------------------------- 导入导出

func _current_format() -> String:
	if _format_pick != null and _format_pick.get_selected_id() == 1:
		return "json"
	return "csv"


func _format_from_path(path: String) -> String:
	var lower := path.to_lower()
	if lower.ends_with(".json"):
		return "json"
	if lower.ends_with(".csv") or lower.ends_with(".tsv"):
		return "csv"
	return _current_format()


func _filters_for(_fmt: String) -> PackedStringArray:
	# 过滤项必须把「所有支持的格式」放在第一个：
	# 只显示当前格式的话，用户拿着 .csv 去导入 JSON 表时，文件列表看起来是空的
	#（表现就是"选了文件却什么都没发生 / 根本看不到自己的文件"）。
	return PackedStringArray([
		"*.json, *.csv, *.tsv ; 配置数据（JSON / CSV / TSV）",
		"*.json ; JSON 数组",
		"*.csv, *.tsv ; CSV 配置表",
	])


func _on_import() -> void:
	if _guard_schema_dirty():
		return
	if _current_table == "":
		_log("请先选择一张表", COLOR_WARN)
		return
	var fmt := _current_format()
	_dialog_action = "import"
	_ensure_dialog()
	if _dialog == null:
		return
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_dialog.filters = _filters_for(fmt)
	# 回到上次导入的目录，省得每次都从项目根翻过去
	if _last_io_dir != "":
		_dialog.current_dir = _last_io_dir
	var mode_text := "替换全部"
	if _import_mode == "append":
		mode_text = "追加到末尾"
	_dialog.title = "导入到 %s（%s · 需再点「保存表」）" % [_current_table, mode_text]
	_dialog.popup_centered_ratio(0.6)


## 「导入…」下拉：选替换还是追加、用文件对话框还是直接贴路径。
func _on_import_menu(id: int) -> void:
	_import_mode = "replace"
	if id == 1 or id == 3:
		_import_mode = "append"
	if id >= 2:
		_open_path_import()
		return
	_on_import()


## 从路径导入：直接粘贴绝对路径 / res:// 路径，不用在文件对话框里翻目录。
func _open_path_import() -> void:
	if _guard_schema_dirty():
		return
	if _current_table == "":
		_set_status("请先选择一张表")
		_log("请先选择一张表", COLOR_WARN)
		return
	if _path_dialog == null:
		_path_dialog = AcceptDialog.new()
		_path_dialog.title = "从路径导入"
		_path_dialog.dialog_text = "支持绝对路径（E:/data/item.csv）和 res:// 路径；格式按后缀自动判断"
		_path_edit = LineEdit.new()
		_path_edit.custom_minimum_size = Vector2(520, 0)
		_path_edit.placeholder_text = "E:/data/item.csv   或   res://configforge/Data/item.json"
		_path_dialog.add_child(_path_edit)
		_path_dialog.register_text_enter(_path_edit)
		_path_dialog.confirmed.connect(_on_path_confirmed)
		add_child(_path_dialog)
	_path_edit.text = ""
	_path_dialog.popup_centered(Vector2i(600, 140))
	_path_edit.grab_focus()


func _on_path_confirmed() -> void:
	var path := _path_edit.text.strip_edges()
	if path == "":
		return
	_do_import_file(path, _import_mode)


func _on_export() -> void:
	if _guard_schema_dirty():
		return
	if _current_table == "":
		_log("请先选择一张表", COLOR_WARN)
		return
	var fmt := _current_format()
	_dialog_action = "export"
	_ensure_dialog()
	if _dialog == null:
		return
	_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_dialog.filters = _filters_for(fmt)
	if _last_io_dir != "":
		_dialog.current_dir = _last_io_dir
	_dialog.title = "导出 %s（%s）" % [_current_table, fmt.to_upper()]
	_dialog.current_file = _current_table.to_lower() + "." + fmt
	_dialog.popup_centered_ratio(0.6)


func _ensure_dialog() -> void:
	if _dialog != null and is_instance_valid(_dialog):
		return
	_dialog = FileDialog.new()
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.use_native_dialog = false
	_dialog.file_selected.connect(_on_dialog_file_selected)
	add_child(_dialog)


func _on_dialog_file_selected(path: String) -> void:
	var fmt := _format_from_path(path)
	var lower := path.to_lower()
	if not (lower.ends_with(".json") or lower.ends_with(".csv") or lower.ends_with(".tsv")):
		path = path + "." + fmt

	if _dialog_action == "export":
		_last_io_dir = path.get_base_dir()
		var result := _pipeline.export_table(_current_table, path, fmt)
		if bool(result["ok"]):
			_log("已导出 %s（%s）→ %s" % [_current_table, fmt.to_upper(), path], COLOR_OK)
			if fmt == "csv" and _table_has_nested(_current_table):
				_log("提示：该表含结构字段，CSV 表达不了嵌套，要完整数据请改用 JSON 导出", COLOR_WARN)
		else:
			_log("导出失败：" + str(result["error"]), COLOR_ERR)
		return

	if _dialog_action == "import":
		_do_import_file(path, _import_mode)


## 真正执行导入：文件对话框和「从路径导入」共用这一段。
func _do_import_file(path: String, mode: String) -> void:
	if not FileAccess.file_exists(path):
		_log("导入失败：文件不存在 %s" % path, COLOR_ERR)
		_set_status("导入失败：文件不存在", COLOR_ERR)
		return
	var fmt := _format_from_path(path)
	var text := FileAccess.get_file_as_string(path)
	_last_io_dir = path.get_base_dir()
	var result2 := _pipeline.import_table(_current_table, text, fmt, path, mode)
	var issues2: Array = result2.get("issues", [])
	if bool(result2["ok"]):
		var count := int(result2.get("count", 0))
		var skipped := int(result2.get("skipped", 0))
		var msg := "已导入 %d 条到 %s" % [count, _current_table]
		if skipped > 0:
			msg += "（跳过 %d 条重复索引）" % skipped
		msg += "，未保存，点「保存表」写回"
		_log(msg, COLOR_WARN)
		_refresh_grid()
		_pipeline.validate()
		_show_issues(_pipeline.issues)
		_update_status()
		if _tab != null:
			_tab.current_tab = TAB_TABLES
		_set_status(msg, COLOR_OK)
		return
	# 失败要给得出结论：状态栏一句话 + 切到日志页看具体哪几行哪几列
	var reason := str(result2.get("error", "导入失败"))
	_set_status("导入被拒绝：" + reason, COLOR_ERR)
	_log("导入被拒绝：" + reason, COLOR_ERR)
	var shown := 0
	for it in issues2:
		if str(it.get("severity", "")) == CFIssue.ERROR:
			_log(CFIssue.format(it), COLOR_ERR)
			shown += 1
			if shown >= 8:
				_log("…… 共 %d 条错误，其余见结构/数据校验" % CFIssue.count_errors(issues2), COLOR_ERR)
				break
	if _tab != null:
			_tab.current_tab = TAB_LOG


func _table_has_nested(table_name: String) -> bool:
	var table := _pipeline.schema.table_by_name(table_name)
	if table.is_empty():
		return false
	for f in table["bean"]["fields"]:
		var kind := str(f["kind"])
		if kind == "bean":
			return true
		if kind == "list" and str(f["info"].get("elem", {}).get("kind", "")) == "bean":
			return true
		if kind == "map" and str(f["info"].get("value", {}).get("kind", "")) == "bean":
			return true
	return false


func _on_clear_issues() -> void:
	_pipeline.issues.clear()
	_show_issues([])
	_set_status("校验结果已清空（点「校验」重新生成）")
	_log("已清空校验结果列表", COLOR_DIM)


func _on_clear_log() -> void:
	_clear_log()
	_log("日志已清空", COLOR_DIM)


# ---------------------------------------------------------------- 结构页

func _refresh_schema_tree() -> void:
	if _schema_tree == null:
		return
	# 重建前先记下哪些节点是展开的，重建后恢复 —— 否则每次刷新整棵树都会"回弹"收回
	var expanded := _expanded_keys()
	_cancel_cell_edit()
	_schema_tree.clear()
	_schema_tree.columns = 4
	_schema_tree.set_column_title(0, "名称")
	_schema_tree.set_column_title(1, "类型")
	_schema_tree.set_column_title(2, "约束 / 分组")
	_schema_tree.set_column_title(3, "说明")
	_schema_tree.set_column_custom_minimum_width(0, 170)
	_schema_tree.set_column_custom_minimum_width(1, 110)
	_schema_tree.set_column_custom_minimum_width(2, 160)
	_schema_tree.set_column_expand(0, true)
	_schema_tree.set_column_expand(3, true)

	var root := _schema_tree.create_item()
	_build_enum_nodes(root)
	_build_bean_nodes(root)
	_build_table_nodes(root)
	_apply_expanded(expanded)
	_update_schema_count()


# ---------------------------------------------------------------- 结构树展开状态

## 让四列都能点选。
## Godot 的 TreeItem 非首列默认不一定可选，导致「类型」「约束/分组」两列点不中，
## 也就进不了编辑状态（双击改不了）。这里统一把 0~3 列都设为可选。
func _make_selectable(item: TreeItem) -> void:
	for c in range(4):
		item.set_selectable(c, true)

## 记录当前展开的节点。key = "kind:name"，重建后按 key 恢复。
func _expanded_keys() -> Dictionary:
	var out: Dictionary = {}
	var root := _schema_tree.get_root()
	if root != null:
		_collect_expanded(root, out)
	return out


func _collect_expanded(parent: TreeItem, out: Dictionary) -> void:
	for i in range(parent.get_child_count()):
		var child := parent.get_child(i)
		var meta: Variant = child.get_metadata(0)
		if meta is Dictionary:
			var key := _node_key(meta)
			if key != "" and not child.is_collapsed():
				out[key] = true
		_collect_expanded(child, out)


func _apply_expanded(keys: Dictionary) -> void:
	var root := _schema_tree.get_root()
	if root != null:
		_apply_expanded_rec(root, keys)


func _apply_expanded_rec(parent: TreeItem, keys: Dictionary) -> void:
	for i in range(parent.get_child_count()):
		var child := parent.get_child(i)
		var meta: Variant = child.get_metadata(0)
		if meta is Dictionary:
			var key := _node_key(meta)
			if key != "" and keys.has(key):
				child.set_collapsed(false)
		_apply_expanded_rec(child, keys)


## 节点的稳定标识（用于跨重建保持展开状态与定位）。
func _node_key(meta: Dictionary) -> String:
	var kind := str(meta.get("kind", ""))
	if kind == "bean":
		return "bean:" + str(meta.get("name", ""))
	if kind == "enum":
		return "enum:" + str(meta.get("name", ""))
	if kind == "inherit":
		return "inherit:" + str(meta.get("bean", "")) + ":" + str(meta.get("name", ""))
	if kind == "group":
		return "group:" + str(meta.get("name", ""))
	return ""


## 按「kind + name」找节点（递归）。
func _find_node(parent: TreeItem, kind: String, name: String) -> TreeItem:
	for i in range(parent.get_child_count()):
		var child := parent.get_child(i)
		var meta: Variant = child.get_metadata(0)
		if meta is Dictionary and str(meta.get("kind", "")) == kind and str(meta.get("name", "")) == name:
			return child
		var hit := _find_node(child, kind, name)
		if hit != null:
			return hit
	return null


## 把某节点和它的所有祖先都展开（这样滚动定位时不会被收起的父节点挡住）。
func _expand_to(item: TreeItem) -> void:
	var node := item
	while node != null:
		node.set_collapsed(false)
		node = node.get_parent()


## 展开并选中某个结构（删除字段后用）。
func _reveal_bean(bean_name: String) -> void:
	if _schema_tree == null:
		return
	var root := _schema_tree.get_root()
	if root == null:
		return
	var bean_item := _find_node(root, "bean", bean_name)
	if bean_item == null:
		return
	_expand_to(bean_item)
	bean_item.select(0)
	_schema_tree.scroll_to_item(bean_item)


## 展开结构并选中其中某个字段（新增字段后用：让用户直接看到新字段在哪）。
func _reveal_field(bean_name: String, field_name: String) -> void:
	if _schema_tree == null:
		return
	var root := _schema_tree.get_root()
	if root == null:
		return
	var bean_item := _find_node(root, "bean", bean_name)
	if bean_item == null:
		return
	_expand_to(bean_item)
	for i in range(bean_item.get_child_count()):
		var child := bean_item.get_child(i)
		var meta: Variant = child.get_metadata(0)
		if meta is Dictionary and str(meta.get("kind", "")) == "field" and str(meta.get("name", "")) == field_name:
			child.select(0)
			_schema_tree.scroll_to_item(child)
			return
	bean_item.select(0)
	_schema_tree.scroll_to_item(bean_item)


func _build_enum_nodes(root: TreeItem) -> void:
	var enums_root := _schema_tree.create_item(root)
	_make_selectable(enums_root)
	enums_root.set_text(0, "枚举（%d）" % _pipeline.schema.enums.size())
	enums_root.set_metadata(0, {"kind": "group", "name": "enums"})
	for ename in _pipeline.schema.enums.keys():
		var e: Dictionary = _pipeline.schema.enums[ename]
		var values: Dictionary = e.get("values", {})
		var aliases: Dictionary = e.get("aliases", {})
		var probe: Array = [str(ename)]
		for vname in values.keys():
			probe.append(str(vname))
		if not _schema_match(probe):
			continue
		var item := _schema_tree.create_item(enums_root)
		_make_selectable(item)
		item.set_text(0, str(ename))
		item.set_text(1, "enum")
		item.set_text(2, "%d 个取值" % values.size())
		item.set_text(3, str(e.get("comment", "")))
		item.set_metadata(0, {"kind": "enum", "name": str(ename)})
		item.set_tooltip_text(0, "双击改枚举名；改完记得把引用它的字段类型一起改")
		item.set_tooltip_text(3, "双击改说明")
		item.set_collapsed(true)
		# aliases 是「别名 → 数值」，这里反过来做成「数值 → 别名」方便下面查
		var alias_of: Dictionary = {}
		for k in aliases.keys():
			alias_of[int(aliases[k])] = str(k)
		for vname in values.keys():
			var vval := int(values[vname])
			var value_item := _schema_tree.create_item(item)
			_make_selectable(value_item)
			value_item.set_text(0, str(vname))
			value_item.set_text(1, str(vval))
			var alias := str(alias_of.get(vval, ""))
			if alias != "":
				value_item.set_text(2, "别名 " + alias)
			value_item.set_metadata(0, {"kind": "enum_value", "enum": str(ename), "name": str(vname)})
			value_item.set_tooltip_text(0, "双击改取值名")
			value_item.set_tooltip_text(1, "双击改数值（整数）")


func _build_bean_nodes(root: TreeItem) -> void:
	var beans_root := _schema_tree.create_item(root)
	_make_selectable(beans_root)
	beans_root.set_text(0, "结构（%d）" % _pipeline.schema.beans.size())
	beans_root.set_metadata(0, {"kind": "group", "name": "beans"})
	for bname in _pipeline.schema.beans.keys():
		var b: Dictionary = _pipeline.schema.beans[bname]
		var probe: Array = [str(bname)]
		for f in b["fields"]:
			probe.append(str(f["name"]))
		if not _schema_match(probe):
			continue
		var bean_item := _schema_tree.create_item(beans_root)
		_make_selectable(bean_item)
		bean_item.set_text(0, str(bname))
		var parent := str(b["parent"])
		bean_item.set_text(1, "bean")
		var tags: Array = []
		if parent != "":
			tags.append("继承 " + parent)
		if bool(b.get("polymorphic", false)):
			tags.append("多态")
		if bool(b.get("abstract", false)):
			tags.append("抽象")
		bean_item.set_text(2, " · ".join(PackedStringArray(tags)))
		bean_item.set_text(3, str(b.get("comment", "")))
		bean_item.set_metadata(0, {"kind": "bean", "name": str(bname)})
		bean_item.set_tooltip_text(0, "结构名不建议直接改；要改名请同步改引用它的表 / 字段")
		bean_item.set_tooltip_text(3, "双击改说明")
		bean_item.set_collapsed(true)

		var own_names: Dictionary = {}
		var raw_bean: Dictionary = _pipeline.schema.raw_bean(str(bname))
		var raw_fields: Array = raw_bean.get("fields", [])
		for i in range(raw_fields.size()):
			var rf: Dictionary = raw_fields[i]
			var fname := str(rf.get("name", ""))
			own_names[fname] = true
			var norm := _pipeline.schema.bean_field(str(bname), fname)
			if norm.is_empty():
				continue
			var field_item := _schema_tree.create_item(bean_item)
			_make_selectable(field_item)
			field_item.set_text(0, fname)
			field_item.set_text(1, str(norm["type"]))
			field_item.set_text(2, _field_marks(norm))
			field_item.set_text(3, str(norm.get("comment", "")))
			field_item.set_metadata(0, {"kind": "field", "bean": str(bname), "index": i, "name": fname})
			field_item.set_tooltip_text(2, _field_tooltip(norm))

		var inherited: Array = []
		for f in b["fields"]:
			if not own_names.has(str(f["name"])):
				inherited.append(f)
		if not inherited.is_empty():
			var inherited_root := _schema_tree.create_item(bean_item)
			_make_selectable(inherited_root)
			inherited_root.set_text(0, "继承自 %s（%d 个字段）" % [parent, inherited.size()])
			inherited_root.set_custom_color(0, _dim_color)
			inherited_root.set_metadata(0, {"kind": "inherit", "bean": str(bname), "name": parent})
			for f in inherited:
				var item2 := _schema_tree.create_item(inherited_root)
				_make_selectable(item2)
				item2.set_text(0, str(f["name"]))
				item2.set_text(1, str(f["type"]))
				item2.set_text(2, _field_marks(f))
				item2.set_text(3, str(f.get("comment", "")))
				item2.set_custom_color(0, _dim_color)
				item2.set_custom_color(1, _dim_color)


func _build_table_nodes(root: TreeItem) -> void:
	var tables_root := _schema_tree.create_item(root)
	_make_selectable(tables_root)
	tables_root.set_text(0, "表（%d）" % _pipeline.schema.tables.size())
	tables_root.set_metadata(0, {"kind": "group", "name": "tables"})
	for t in _pipeline.schema.tables:
		if not _schema_match([str(t["name"])]):
			continue
		var table_item := _schema_tree.create_item(tables_root)
		_make_selectable(table_item)
		table_item.set_text(0, str(t["name"]))
		table_item.set_text(1, "%s · %s" % [str(t["source"]), str(t["mode"])])
		var group := str(t["group"])
		if group == "":
			table_item.set_text(2, "—")
			table_item.set_custom_color(2, _dim_color)
		else:
			table_item.set_text(2, group)
		table_item.set_text(3, str(t["comment"]))
		table_item.set_metadata(0, {"kind": "table", "name": str(t["name"])})
		table_item.set_tooltip_text(0, "双击改表名（生成的数据文件名会跟着变）")
		table_item.set_tooltip_text(1, "%s → %s.json · 索引 %s" % [str(t["input"]), str(t["file_stem"]), str(t["index"])])
		table_item.set_tooltip_text(2, "双击改分组（生成时可用 --group 过滤）")
		table_item.set_tooltip_text(3, "双击改说明")


## 字段的「约束 / 标记」摘要（结构页与单元格 tooltip 共用同一套说法）。
func _field_marks(field: Dictionary) -> String:
	var parts: Array = []
	if str(field["ref"]) != "":
		parts.append("ref→" + str(field["ref"]))
	var min_v: Variant = field.get("min", null)
	var max_v: Variant = field.get("max", null)
	if min_v != null and max_v != null:
		parts.append("%s~%s" % [_to_text(min_v), _to_text(max_v)])
	elif min_v != null:
		parts.append("≥" + _to_text(min_v))
	elif max_v != null:
		parts.append("≤" + _to_text(max_v))
	var len_min := int(field.get("len_min", 0))
	var len_max := int(field.get("len_max", 0))
	if len_max > 0:
		parts.append("长度 %d~%d" % [len_min, len_max])
	elif len_min > 0:
		parts.append("长度 ≥%d" % len_min)
	if str(field.get("pattern", "")) != "":
		parts.append("正则")
	if str(field.get("path", "")) != "":
		parts.append("资源路径")
	var kind := str(field["kind"])
	if kind == "list" or kind == "map":
		parts.append("sep=" + str(field["sep"]))
	if not bool(field.get("required", true)):
		parts.append("可空")
	return " · ".join(PackedStringArray(parts))


## 双击结构树单元格 → 打开内嵌输入框（单击只选中）。
func _on_schema_activated() -> void:
	_begin_edit_at_selected(_schema_tree)


## 结构页的双击提交：按节点类型分派（字段 / 枚举 / 枚举取值 / 表）。
func _on_schema_edited(item: TreeItem = null, col: int = -1) -> void:
	if _schema_tree == null:
		return
	if item == null:
		item = _schema_tree.get_edited()
		col = _schema_tree.get_edited_column()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if not (meta is Dictionary):
		return
	var kind := str(meta.get("kind", ""))
	if kind == "field":
		_edit_field(meta, col, item)
	elif kind == "bean":
		_edit_bean(meta, col, item)
	elif kind == "enum":
		_edit_enum(meta, col, item)
	elif kind == "enum_value":
		_edit_enum_value(meta, col, item)
	elif kind == "table":
		_edit_table(meta, col, item)


## 字段：第 0 列改名字，第 1 列改类型。
func _edit_field(meta: Dictionary, col: int, item: TreeItem) -> void:
	if col != 0 and col != 1:
		return
	var bean_name := str(meta.get("bean", ""))
	var bean := _pipeline.schema.raw_bean(bean_name)
	if bean.is_empty():
		return
	var fields: Array = bean.get("fields", [])
	var idx := int(meta.get("index", -1))
	if idx < 0 or idx >= fields.size():
		return
	var rf: Dictionary = fields[idx]
	if col == 0:
		var new_name := item.get_text(0).strip_edges()
		if new_name == "":
			item.set_text(0, str(rf.get("name", "")))
			_set_status("字段名不能为空")
			return
		rf["name"] = new_name
	else:
		var new_type := item.get_text(1).strip_edges()
		if new_type == "":
			item.set_text(1, str(rf.get("type", "")))
			_set_status("字段类型不能为空")
			return
		rf["type"] = new_type
	item.set_metadata(0, {"kind": "field", "bean": bean_name, "index": idx, "name": str(rf["name"])})
	_after_schema_edit("结构 %s 的字段 %s 已改" % [bean_name, str(rf["name"])], true)


## 结构（bean）：只放开了第 3 列（说明）；改名会牵动表和字段引用，不在这里改。
func _edit_bean(meta: Dictionary, col: int, item: TreeItem) -> void:
	if col != 3:
		return
	var bname := str(meta.get("name", ""))
	var bean := _pipeline.schema.raw_bean(bname)
	if bean.is_empty():
		return
	bean["comment"] = item.get_text(3).strip_edges().replace("\n", " ")
	_after_schema_edit("结构 %s 的说明已改" % bname, false)


## 枚举：第 0 列改枚举名，第 3 列改说明。
func _edit_enum(meta: Dictionary, col: int, item: TreeItem) -> void:
	var ename := str(meta.get("name", ""))
	var raw_enum := _pipeline.schema.raw_enum(ename)
	if raw_enum.is_empty():
		return
	if col == 0:
		var new_name := item.get_text(0).strip_edges()
		if new_name == "":
			item.set_text(0, ename)
			_set_status("枚举名不能为空")
			return
		raw_enum["name"] = new_name
		_after_schema_edit("枚举 %s 改名为 %s（引用它的字段类型要一起改）" % [ename, new_name], true)
		return
	if col == 3:
		raw_enum["comment"] = item.get_text(3).strip_edges().replace("\n", " ")
		_after_schema_edit("枚举 %s 的说明已改" % ename, false)


## 枚举取值：第 0 列改取值名，第 1 列改数值。
func _edit_enum_value(meta: Dictionary, col: int, item: TreeItem) -> void:
	if col != 0 and col != 1:
		return
	var ename := str(meta.get("enum", ""))
	var vname := str(meta.get("name", ""))
	var raw_enum := _pipeline.schema.raw_enum(ename)
	if raw_enum.is_empty():
		return
	var values: Variant = raw_enum.get("values", null)
	# schema 里 values 支持两种写法：数组 [{name,value,alias}] 或对象 {name: value}。
	# 示例 schema 用的是数组写法，所以两种都要能改。
	if values is Array:
		_edit_enum_value_array(raw_enum, values, ename, vname, col, item)
		return
	if not (values is Dictionary):
		return
	var dict: Dictionary = values
	if col == 0:
		var new_name := item.get_text(0).strip_edges()
		if new_name == "":
			item.set_text(0, vname)
			_set_status("取值名不能为空")
			return
		if new_name != vname and dict.has(new_name):
			item.set_text(0, vname)
			_set_status("改名失败：取值 %s 已存在" % new_name)
			return
		var old_val: Variant = dict.get(vname, 0)
		dict.erase(vname)
		dict[new_name] = old_val
		raw_enum["values"] = dict
		_after_schema_edit("枚举 %s 的取值 %s 改名为 %s" % [ename, vname, new_name], true)
		return
	var new_val := item.get_text(1).strip_edges()
	if not new_val.is_valid_int():
		item.set_text(1, str(dict.get(vname, 0)))
		_set_status("数值必须是整数：%s" % new_val)
		return
	dict[vname] = int(new_val)
	raw_enum["values"] = dict
	_after_schema_edit("枚举 %s 的 %s = %s" % [ename, vname, new_val], true)


## values 是数组写法时的取值编辑。
func _edit_enum_value_array(raw_enum: Dictionary, arr: Array, ename: String, vname: String, col: int, item: TreeItem) -> void:
	var found := -1
	for i in range(arr.size()):
		var v: Variant = arr[i]
		if v is Dictionary and str(v.get("name", "")) == vname:
			found = i
			break
	if found < 0:
		return
	var entry: Dictionary = arr[found]
	if col == 0:
		var new_name := item.get_text(0).strip_edges()
		if new_name == "":
			item.set_text(0, vname)
			_set_status("取值名不能为空")
			return
		if new_name != vname:
			for i in range(arr.size()):
				var v: Variant = arr[i]
				if v is Dictionary and str(v.get("name", "")) == new_name:
					item.set_text(0, vname)
					_set_status("改名失败：取值 %s 已存在" % new_name)
					return
		entry["name"] = new_name
		arr[found] = entry
		raw_enum["values"] = arr
		_after_schema_edit("枚举 %s 的取值 %s 改名为 %s" % [ename, vname, new_name], true)
		return
	var new_val := item.get_text(1).strip_edges()
	if not new_val.is_valid_int():
		item.set_text(1, str(int(entry.get("value", 0))))
		_set_status("数值必须是整数：%s" % new_val)
		return
	entry["value"] = int(new_val)
	arr[found] = entry
	raw_enum["values"] = arr
	_after_schema_edit("枚举 %s 的 %s = %s" % [ename, vname, new_val], true)


## 表：第 0 列改表名，第 2 列改分组，第 3 列改说明。
func _edit_table(meta: Dictionary, col: int, item: TreeItem) -> void:
	var tname := str(meta.get("name", ""))
	var raw_table := _pipeline.schema.raw_table(tname)
	if raw_table.is_empty():
		return
	if col == 0:
		var new_name := item.get_text(0).strip_edges()
		if new_name == "":
			item.set_text(0, tname)
			_set_status("表名不能为空")
			return
		raw_table["name"] = new_name
		_after_schema_edit("表 %s 改名为 %s（数据文件名会跟着变）" % [tname, new_name], true)
		return
	if col == 2:
		var group := item.get_text(2).strip_edges()
		if group == "—":
			group = ""
		raw_table["group"] = group
		_after_schema_edit("表 %s 的分组改为 %s" % [tname, group if group != "" else "（无）"], true)
		return
	if col == 3:
		raw_table["comment"] = item.get_text(3).strip_edges().replace("\n", " ")
		_after_schema_edit("表 %s 的说明已改" % tname, false)


## 结构改完后的统一收尾：重新解析 → 刷新 → 计数 → 状态栏/日志。
func _after_schema_edit(message: String, rebuild_tree: bool) -> void:
	_schema_edits += 1
	_pipeline.schema.reparse()
	if rebuild_tree:
		_refresh_schema_tree()
	_refresh_grid()
	_update_status()
	_set_status(message + "（未保存，点「保存结构」写回）", COLOR_WARN)
	_log(message + "（未保存）", COLOR_WARN)


func _on_schema_search_changed(_text: String) -> void:
	_refresh_schema_tree()


## 结构树筛选：probe 里任一项命中关键字就显示（空筛选 = 全显示）。
func _schema_match(probe: Array) -> bool:
	var filter := ""
	if _schema_search != null:
		filter = _schema_search.text.strip_edges().to_lower()
	if filter == "":
		return true
	for p in probe:
		if str(p).to_lower().find(filter) >= 0:
			return true
	return false


func _update_schema_count() -> void:
	if _schema_count == null:
		return
	_schema_count.text = "%d 结构 · %d 枚举 · %d 表" % [
		_pipeline.schema.beans.size(),
		_pipeline.schema.enums.size(),
		_pipeline.schema.tables.size()]


func _on_save_schema() -> void:
	var ok := _pipeline.schema.save_to_file(_pipeline.schema_path)
	if not ok:
		_log("结构保存失败", COLOR_ERR)
		for it in _pipeline.schema.issues:
			_log(CFIssue.format(it), COLOR_ERR)
		return
	_schema_edits = 0
	_scan_filesystem()
	reload_all()
	_log("结构已保存 → %s" % _pipeline.schema_path, COLOR_OK)


func _selected_bean() -> String:
	if _schema_tree == null:
		return ""
	var item := _schema_tree.get_selected()
	if item == null:
		return ""
	var meta: Variant = item.get_metadata(0)
	if meta is Dictionary and meta.has("bean"):
		return str(meta["bean"])
	if meta is Dictionary and meta.has("name") and str(meta.get("kind", "")) == "bean":
		return str(meta["name"])
	return ""


func _on_add_field() -> void:
	var bname := _selected_bean()
	if bname == "":
		# 没在结构页选中结构时，退回用「表数据」页当前表的结构，避免点了像没反应
		var cur := _pipeline.schema.table_by_name(_current_table)
		if not cur.is_empty():
			bname = str(cur["bean_name"])
	if bname == "":
		_log("请先在「结构」页选中一个结构（或其字段），或先在「表数据」页选一张表", COLOR_WARN)
		_set_status("新增字段失败：当前没有选中的结构")
		return
	var bean := _pipeline.schema.raw_bean(bname)
	if bean.is_empty():
		_log("找不到结构 %s 的原始定义" % bname, COLOR_ERR)
		return
	var fields: Array = bean.get("fields", [])
	var used: Dictionary = {}
	for f in fields:
		if f is Dictionary:
			used[str(f.get("name", ""))] = true
	var new_name := "new_field"
	var n := 2
	while used.has(new_name):
		new_name = "new_field_%d" % n
		n += 1
	fields.append({"name": new_name, "type": "int", "comment": ""})
	bean["fields"] = fields
	_schema_edits += 1
	# raw 改完必须 reparse：bean_field() 只看解析后的模型，不刷新的话新字段显示不出来
	_pipeline.schema.reparse()
	_refresh_schema_tree()
	_refresh_grid()
	_reveal_field(bname, new_name)
	_set_status("已为 %s 新增字段 %s（未保存，点「保存结构」写回）" % [bname, new_name], COLOR_OK)
	_log("已为结构 %s 新增字段 %s（未保存）" % [bname, new_name], COLOR_WARN)


func _on_delete_field() -> void:
	if _schema_tree == null:
		return
	var item := _schema_tree.get_selected()
	if item == null:
		_log("请在「结构」页选中要删除的字段", COLOR_WARN)
		return
	var meta: Variant = item.get_metadata(0)
	if not (meta is Dictionary) or str(meta.get("kind", "")) != "field":
		_log("只能删除结构里的字段行", COLOR_WARN)
		return
	var bname := str(meta["bean"])
	var bean := _pipeline.schema.raw_bean(bname)
	if bean.is_empty():
		return
	var fields: Array = bean.get("fields", [])
	var idx := int(meta["index"])
	if idx < 0 or idx >= fields.size():
		return
	var removed: Variant = fields[idx]
	fields.remove_at(idx)
	bean["fields"] = fields
	_schema_edits += 1
	_pipeline.schema.reparse()
	_refresh_schema_tree()
	_refresh_grid()
	_reveal_bean(bname)
	_set_status("已删除字段 %s（未保存，点「保存结构」写回）" % str(removed.get("name", "")), COLOR_OK)
	_log("已删除结构 %s 的字段 %s（未保存）" % [bname, str(removed.get("name", ""))], COLOR_WARN)


# ---------------------------------------------------------------- 枚举 / 表的增删

## 选中节点对应的枚举名（选中枚举或它的取值行都算）。
func _selected_enum() -> String:
	if _schema_tree == null:
		return ""
	var item := _schema_tree.get_selected()
	if item == null:
		return ""
	var meta: Variant = item.get_metadata(0)
	if not (meta is Dictionary):
		return ""
	var kind := str(meta.get("kind", ""))
	if kind == "enum":
		return str(meta.get("name", ""))
	if kind == "enum_value":
		return str(meta.get("enum", ""))
	return ""


## 选中节点对应的表名。
func _selected_table() -> String:
	if _schema_tree == null:
		return ""
	var item := _schema_tree.get_selected()
	if item == null:
		return ""
	var meta: Variant = item.get_metadata(0)
	if meta is Dictionary and str(meta.get("kind", "")) == "table":
		return str(meta.get("name", ""))
	return ""


## 字段类型是不是这个枚举（含 list / map 的元素类型）。
func _type_uses_enum(field: Dictionary, enum_name: String) -> bool:
	var info: Dictionary = field.get("info", {})
	if str(info.get("kind", "")) == "enum" and str(info.get("type", "")) == enum_name:
		return true
	var elem: Dictionary = info.get("elem", {})
	if str(elem.get("kind", "")) == "enum" and str(elem.get("type", "")) == enum_name:
		return true
	var val: Dictionary = info.get("value", {})
	if str(val.get("kind", "")) == "enum" and str(val.get("type", "")) == enum_name:
		return true
	return false


## 哪些字段在用这个枚举，返回 ["Item.quality", ...]。
func _enum_refs(enum_name: String) -> Array:
	var out: Array = []
	for bname in _pipeline.schema.beans.keys():
		var b: Dictionary = _pipeline.schema.beans[bname]
		for f in b["fields"]:
			if _type_uses_enum(f, enum_name):
				out.append("%s.%s" % [str(bname), str(f["name"])])
	return out


## 哪些字段 ref 指向这张表。
func _table_refs(table_name: String) -> Array:
	var out: Array = []
	for bname in _pipeline.schema.beans.keys():
		var b: Dictionary = _pipeline.schema.beans[bname]
		for f in b["fields"]:
			if str(f.get("ref", "")) == table_name:
				out.append("%s.%s" % [str(bname), str(f["name"])])
	return out


## 按 kind 定位并选中节点（枚举 / 表用）。
func _reveal_kind(kind: String, node_name: String) -> void:
	if _schema_tree == null:
		return
	var root := _schema_tree.get_root()
	if root == null:
		return
	var node := _find_node(root, kind, node_name)
	if node == null:
		return
	_expand_to(node)
	node.select(0)
	_schema_tree.scroll_to_item(node)


func _on_add_enum() -> void:
	var enum_name := "NewEnum"
	var n := 2
	while not _pipeline.schema.raw_enum(enum_name).is_empty():
		enum_name = "NewEnum%d" % n
		n += 1
	if not _pipeline.schema.add_enum(enum_name, ""):
		_set_status("新增枚举失败（名字冲突）")
		return
	_schema_edits += 1
	_pipeline.schema.reparse()
	_refresh_schema_tree()
	_reveal_kind("enum", enum_name)
	_set_status("已新增枚举 %s（未保存，点「保存结构」写回）" % enum_name, COLOR_OK)
	_log("已新增枚举 %s（默认取值 Common = 1，未保存）" % enum_name, COLOR_WARN)


func _on_delete_enum() -> void:
	var enum_name := _selected_enum()
	if enum_name == "":
		_set_status("删除枚举失败：先在结构页选中一个枚举（或它的任一取值）")
		_log("请先在结构页选中要删除的枚举", COLOR_WARN)
		return
	var refs := _enum_refs(enum_name)
	if not refs.is_empty():
		_set_status("不能删除枚举 %s：仍被 %d 处字段使用" % [enum_name, refs.size()], COLOR_ERR)
		_log("不能删除枚举 %s，被这些字段用着：%s" % [enum_name, str(refs.slice(0, 8))], COLOR_ERR)
		return
	if not _pipeline.schema.remove_enum(enum_name):
		_set_status("删除枚举失败")
		return
	_schema_edits += 1
	_pipeline.schema.reparse()
	_refresh_schema_tree()
	_refresh_grid()
	_set_status("已删除枚举 %s（未保存，点「保存结构」写回）" % enum_name, COLOR_OK)
	_log("已删除枚举 %s（未保存）" % enum_name, COLOR_WARN)


func _on_add_table() -> void:
	# 用哪个结构：优先结构页选中的，其次当前表的结构，最后第一个可用的具体结构
	var bean := ""
	var sel := _selected_bean()
	if sel != "" and _pipeline.schema.beans.has(sel):
		bean = sel
	if bean == "":
		var cur := _pipeline.schema.table_by_name(_current_table)
		if not cur.is_empty():
			bean = str(cur["bean_name"])
	if bean == "":
		for bname in _pipeline.schema.beans.keys():
			var b: Dictionary = _pipeline.schema.beans[bname]
			if bool(b.get("abstract", false)) or not b["variants"].is_empty():
				continue
			bean = str(bname)
			break
	if bean == "":
		_set_status("新增表失败：没有可用的结构")
		_log("新增表失败：需要一个非抽象、非多态的结构当表的 bean", COLOR_ERR)
		return
	var table_name := "TbNew"
	var n := 2
	while not _pipeline.schema.raw_table(table_name).is_empty():
		table_name = "TbNew%d" % n
		n += 1
	var input := table_name.to_lower() + ".json"
	if not _pipeline.schema.add_table(table_name, bean, input, "map", "id", "", ""):
		_set_status("新增表失败（名字冲突或参数为空）")
		return
	_pipeline.schema.reparse()
	# 建表的同时把空数据文件写出来，否则下次加载会报 E_DATA_MISSING
	var table := _pipeline.schema.table_by_name(table_name)
	if not table.is_empty():
		var file_path := _pipeline.data_dir.rstrip("/") + "/" + str(table["file_name"])
		_pipeline.tables[table_name] = {"name": table_name, "records": [], "lines": [], "issues": [], "file": file_path}
		var saved := _pipeline.save_table(table_name)
		if not bool(saved["ok"]):
			_log("空数据文件写入失败：" + str(saved["error"]), COLOR_ERR)
	_schema_edits += 1
	_rebuild_picker()
	_select_picker(table_name)
	_refresh_schema_tree()
	_refresh_grid()
	_reveal_kind("table", table_name)
	_set_status("已新增表 %s（bean=%s · 数据源 %s · 结构未保存）" % [table_name, bean, input], COLOR_OK)
	_log("已新增表 %s → %s（空数据文件已生成，结构未保存）" % [table_name, input], COLOR_WARN)


func _on_delete_table() -> void:
	var table_name := _selected_table()
	if table_name == "":
		_set_status("删除表失败：先在结构页选中一张表")
		_log("请先在结构页选中要删除的表", COLOR_WARN)
		return
	var refs := _table_refs(table_name)
	if not refs.is_empty():
		_set_status("不能删除表 %s：仍被 %d 处字段 ref 引用" % [table_name, refs.size()], COLOR_ERR)
		_log("不能删除表 %s，被这些字段引用：%s" % [table_name, str(refs.slice(0, 8))], COLOR_ERR)
		return
	var table := _pipeline.schema.table_by_name(table_name)
	var file_name := str(table.get("file_name", ""))
	if not _pipeline.schema.remove_table(table_name):
		_set_status("删除表失败")
		return
	_pipeline.tables.erase(table_name)
	_schema_edits += 1
	_pipeline.schema.reparse()
	_rebuild_picker()
	_refresh_schema_tree()
	_refresh_grid()
	_set_status("已删除表 %s（结构未保存；数据文件 %s 保留）" % [table_name, file_name], COLOR_OK)
	_log("已删除表 %s（结构未保存）；数据文件仍保留：%s/%s" % [table_name, _pipeline.data_dir, file_name], COLOR_WARN)


# ---------------------------------------------------------------- 校验页

func _show_issues(list: Array) -> void:
	if _issue_tree == null:
		return
	_issue_tree.clear()
	_issue_tree.columns = 4
	_issue_tree.set_column_title(0, "级别")
	_issue_tree.set_column_title(1, "位置")
	_issue_tree.set_column_title(2, "说明")
	_issue_tree.set_column_title(3, "代码")
	_issue_tree.set_column_expand(0, false)
	_issue_tree.set_column_expand(1, false)
	_issue_tree.set_column_expand(2, true)
	_issue_tree.set_column_custom_minimum_width(0, 56)
	_issue_tree.set_column_custom_minimum_width(1, 220)

	var root := _issue_tree.create_item()
	var sorted_issues := CFIssue.sorted(list)
	for it in sorted_issues:
		var severity := str(it.get("severity", CFIssue.ERROR))
		var is_error := severity == CFIssue.ERROR
		var item := _issue_tree.create_item(root)
		if is_error:
			item.set_text(0, "错误")
			item.set_custom_color(0, COLOR_ERR)
		else:
			item.set_text(0, "警告")
			item.set_custom_color(0, COLOR_WARN)
		item.set_text(1, str(it.get("where", "")))
		item.set_text(2, str(it.get("message", "")))
		item.set_text(3, str(it.get("code", "")))
		item.set_metadata(0, {"table": str(it.get("table", "")), "row": int(it.get("row", 0))})
		item.set_tooltip_text(2, str(it.get("file", "")))


func _on_issue_activated() -> void:
	if _issue_tree == null or _grid == null:
		return
	var item := _issue_tree.get_selected()
	if item == null:
		return
	var meta: Variant = item.get_metadata(0)
	if not (meta is Dictionary):
		return
	var table_name := str(meta.get("table", ""))
	if table_name == "":
		return
	if not _select_picker(table_name):
		return
	if _search != null:
		_search.text = ""
	if _tab != null:
		_tab.current_tab = TAB_TABLES
	_refresh_grid()
	var row := int(meta.get("row", 0))
	if row <= 0:
		return
	var root := _grid.get_root()
	if root == null:
		return
	if row - 1 < root.get_child_count():
		var target: TreeItem = root.get_child(row - 1)
		target.select(0)
		_grid.scroll_to_item(target)


# ---------------------------------------------------------------- 动作

func run_validate() -> void:
	if _guard_schema_dirty():
		return
	if _pipeline.schema == null or _pipeline.schema.tables.is_empty():
		reload_all()
		return
	if _pipeline.tables.is_empty():
		_pipeline.load_data()
	_pipeline.validate()
	_show_issues(_pipeline.issues)
	var errors := CFIssue.count_errors(_pipeline.issues)
	var warnings := CFIssue.count_warnings(_pipeline.issues)
	if errors == 0:
		_log("校验完成：0 个错误 / %d 个警告" % warnings, COLOR_OK)
	else:
		_log("校验完成：%d 个错误 / %d 个警告" % [errors, warnings], COLOR_ERR)
	_update_status()
	if _tab != null:
		_tab.current_tab = TAB_ISSUES


func run_generate() -> void:
	if _guard_schema_dirty():
		return
	if _pipeline.schema == null or _pipeline.schema.tables.is_empty():
		reload_all()
		return
	_log("—— 开始一键生成 ——", COLOR_ACCENT)
	var result := _pipeline.run({"generate": true, "merge": _merge_on()})
	_show_issues(result["issues"])
	if bool(result["ok"]):
		var files: Array = result["files"]
		_log("生成完成：%d 个文件" % files.size(), COLOR_OK)
		for path in files:
			_log("  " + str(path), COLOR_DIM)
		_scan_filesystem()
		if _tab != null:
			_tab.current_tab = TAB_LOG
	else:
		_log("生成中止（阶段 %s），%d 个错误，请先在「校验结果」页修完再生成" % [
			str(result["stage"]), CFIssue.count_errors(result["issues"])], COLOR_ERR)
		if _tab != null:
			_tab.current_tab = TAB_ISSUES
	_rebuild_picker()
	_refresh_grid()
	_refresh_schema_tree()
	_update_status()


## 供插件首次启用时调用：写文件 + 结果打到 Output。返回 { ok, stage }。
func run_generate_silent() -> Dictionary:
	var result := _pipeline.run({"generate": true, "merge": _merge_on()})
	var files: Array = result["files"]
	if bool(result["ok"]):
		print("配置工坊：首次生成完成，写入 %d 个文件：" % files.size())
		for f in files:
			print("  " + str(f))
		_scan_filesystem()
		reload_all()
		return {"ok": true, "stage": str(result["stage"])}
	print("配置工坊：首次生成未通过（阶段 %s），%d 个错误" % [
		str(result["stage"]), CFIssue.count_errors(result["issues"])])
	for it in result["issues"]:
		if str(it.get("severity", "")) == CFIssue.ERROR:
			print("  " + CFIssue.format(it))
	push_warning("配置工坊：首次生成未通过，详情见面板「校验结果」页")
	reload_all()
	return {"ok": false, "stage": str(result["stage"])}


func _merge_on() -> bool:
	if _merge_check == null:
		return false
	return _merge_check.button_pressed


# ---------------------------------------------------------------- 杂项

func _update_status() -> void:
	var stats := _pipeline.stats()
	_set_status("%d 枚举 · %d 结构 · %d 表 · %d 条记录 · 错误 %d / 警告 %d" % [
		int(stats.get("enums", 0)),
		int(stats.get("beans", 0)),
		int(stats.get("tables", 0)),
		int(stats.get("records", 0)),
		CFIssue.count_errors(_pipeline.issues),
		CFIssue.count_warnings(_pipeline.issues)])


## 底部状态栏。不传 color 时用主题的次要文字色；传 COLOR_OK / COLOR_WARN / COLOR_ERR
## 强调结果，让"成功/被拒绝/未保存"在界面上有颜色区分。
func _set_status(text: String, color: Color = Color(0, 0, 0, 0)) -> void:
	if _status == null:
		return
	_status.text = text
	if color.a > 0.0:
		_status.add_theme_color_override("font_color", color)
	else:
		_status.add_theme_color_override("font_color", _dim_color)


func _log(text: String, color: Color = COLOR_DIM) -> void:
	if _log_view == null:
		return
	var safe := text.replace("[", "[lb]")
	_log_view.append_text("[color=#%s]%s[/color]\n" % [color.to_html(false), safe])


func _clear_log() -> void:
	if _log_view != null:
		_log_view.clear()


func _scan_filesystem() -> void:
	if not Engine.is_editor_hint():
		return
	# 两条硬性约束（都是编辑器的断言，触发会刷红字）：
	#   1. 正在扫描时再调 scan() → "Condition thread.is_started() is true"
	#   2. 在 call_deferred / 消息队列刷新期间调 scan() → "Do not use progress dialog ..."
	# 所以先让出一帧，再判断是否真的空闲，最后才扫。
	await get_tree().process_frame
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	if fs.is_scanning():
		return
	fs.scan()
