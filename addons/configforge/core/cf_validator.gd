@tool
class_name CFValidator
extends RefCounted

## 配置工坊 · 语义校验
##
## 分工：CFDataLoader 管「类型与必填」（读不进来的值），CFValidator 管「业务语义」：
##   - 索引唯一      E_INDEX_DUPLICATE
##   - 跨表引用      E_REF_MISSING（标量 / list 元素 / map 值都查）
##   - 数值范围      E_RANGE_MIN / E_RANGE_MAX
##   - 字符串长度    E_LEN_MIN / E_LEN_MAX
##   - 正则匹配      E_PATTERN
##   - 资源路径存在  E_PATH_MISSING
##   - set 去重      E_SET_DUPLICATE（加载期已拦，这里兜底 UI 手工编辑）
##   - 未使用的结构/枚举  W_BEAN_UNUSED / W_ENUM_UNUSED（提示清理死配置）
##
## 错误带「[表名] 第 N 条·字段」定位前缀，与 Luban 的 ref/range/path 校验思路一致，
## 区别是本工具把问题做成结构化对象，CLI 可直接输出 JSON 给 Agent / CI。

const WARN_UNUSED_BEAN := "W_BEAN_UNUSED"
const WARN_UNUSED_ENUM := "W_ENUM_UNUSED"


## 校验入口：返回 Array[Dictionary]（已去重、按 error→表→行 排序）。
static func validate(schema: CFSchema, tables: Dictionary) -> Array:
	var issues: Array = []
	issues.append_array(schema.issues)
	if schema.has_errors():
		# 结构本身有错时继续跑数据校验会产生大量级联噪声，只回报结构问题
		return CFIssue.sorted(CFIssue.dedupe(issues))

	var index_sets: Dictionary = {}
	var index_meta: Dictionary = {}
	for table in schema.tables:
		var tname := str(table["name"])
		var loaded: Dictionary = tables.get(tname, {})
		var records: Array = loaded.get("records", [])
		var id_field := schema.index_field(table)
		var id_set: Dictionary = {}
		if not id_field.is_empty():
			var fname := str(id_field["name"])
			for rec in records:
				if rec is Dictionary and rec.has(fname):
					var v: Variant = rec[fname]
					if v != null:
						id_set[v] = true
		index_sets[tname] = id_set
		index_meta[tname] = {
			"field": str(id_field.get("name", "")),
			"kind": str(id_field.get("kind", "")),
			"table": tname,
		}

	var path_cache: Dictionary = {}
	for table in schema.tables:
		var tname := str(table["name"])
		var loaded: Dictionary = tables.get(tname, {})
		var records: Array = loaded.get("records", [])
		var file := str(loaded.get("file", ""))
		var id_field := schema.index_field(table)
		var seen: Dictionary = {}

		# 索引唯一性
		if not id_field.is_empty():
			var id_name := str(id_field["name"])
			for i in range(records.size()):
				var rec: Dictionary = records[i]
				var idv: Variant = rec.get(id_name, null)
				if idv == null:
					continue
				if seen.has(idv):
					issues.append(CFIssue.make(CFIssue.ERROR, "E_INDEX_DUPLICATE",
						"索引 %s=%s 重复（首次出现在第 %d 条）" % [id_name, str(idv), int(seen[idv])],
						{"table": tname, "row": i + 1, "field": id_name, "file": file}))
				else:
					seen[idv] = i + 1

		# 字段级语义
		for i in range(records.size()):
			var rec: Dictionary = records[i]
			for f in table["bean"]["fields"]:
				var fname := str(f["name"])
				if not rec.has(fname):
					continue
				var ctx := {"table": tname, "row": i + 1, "field": fname, "file": file}
				_walk(schema, f, rec[fname], ctx, index_sets, path_cache, issues)

	# 未使用类型提示
	_collect_unused(schema, issues)

	return CFIssue.sorted(CFIssue.dedupe(issues))


# ---------------------------------------------------------------- 递归遍历

static func _walk(schema: CFSchema, field: Dictionary, value: Variant, ctx: Dictionary, index_sets: Dictionary, path_cache: Dictionary, issues: Array) -> void:
	if value == null:
		return
	var kind := str(field["kind"])
	var fname := str(ctx.get("field", field["name"]))

	if kind == "scalar" or kind == "enum":
		if str(field["ref"]) != "":
			_check_ref(schema, field, value, ctx, index_sets, issues)
		if kind == "enum":
			_check_enum(schema, field, value, ctx, issues)
		else:
			_check_leaf(schema, field, value, ctx, path_cache, issues)
		return

	if kind == "list":
		if not (value is Array):
			return
		var elem_f := CFDataLoader.elem_field(field, "elem")
		# 约束声明在外层字段上（min/max/len/pattern/path/ref），逐元素生效
		_copy_constraints(field, elem_f)
		var seen: Dictionary = {}
		for i in range(value.size()):
			var elem: Variant = value[i]
			var elem_ctx := {"table": str(ctx["table"]), "row": ctx["row"], "field": "%s[%d]" % [fname, i], "file": str(ctx["file"])}
			if bool(field["info"].get("is_set", false)) and elem != null:
				if seen.has(elem):
					issues.append(CFIssue.make(CFIssue.ERROR, "E_SET_DUPLICATE",
						"set 容器出现重复元素 %s" % str(elem), elem_ctx))
				seen[elem] = true
			_walk(schema, elem_f, elem, elem_ctx, index_sets, path_cache, issues)
		return

	if kind == "map":
		if not (value is Dictionary):
			return
		var val_field := CFDataLoader.elem_field(field, "value")
		_copy_constraints(field, val_field)
		for k in value.keys():
			var key_ctx := {"table": str(ctx["table"]), "row": ctx["row"], "field": "%s[%s]" % [fname, str(k)], "file": str(ctx["file"])}
			_walk(schema, val_field, value[k], key_ctx, index_sets, path_cache, issues)
		return

	if kind == "bean":
		if not (value is Dictionary):
			return
		var info: Dictionary = field["info"]
		var declared := str(info.get("type", ""))
		var concrete := declared
		if value.has("$type"):
			concrete = str(value["$type"])
		if not schema.beans.has(concrete):
			return
		var sub_ctx := ctx.duplicate(true)
		for bf in schema.beans[concrete]["fields"]:
			var bfname := str(bf["name"])
			if not value.has(bfname):
				continue
			sub_ctx = {"table": str(ctx["table"]), "row": ctx["row"], "field": "%s.%s" % [fname, bfname], "file": str(ctx["file"])}
			_walk(schema, bf, value[bfname], sub_ctx, index_sets, path_cache, issues)
		return


# ---------------------------------------------------------------- 单条规则

## 把外层字段的约束复制到容器元素「伪字段」上，让 _walk 对每个元素都做同一套检查。
static func _copy_constraints(from_field: Dictionary, to_field: Dictionary) -> void:
	to_field["ref"] = str(from_field["ref"])
	to_field["min"] = from_field["min"]
	to_field["max"] = from_field["max"]
	to_field["len_min"] = int(from_field["len_min"])
	to_field["len_max"] = int(from_field["len_max"])
	to_field["pattern"] = str(from_field["pattern"])
	to_field["path"] = str(from_field["path"])


## 跨表引用：值必须存在于目标表的索引字段集合里。
static func _check_ref(schema: CFSchema, field: Dictionary, value: Variant, ctx: Dictionary, index_sets: Dictionary, issues: Array) -> void:
	if value == null:
		return
	var target := str(field["ref"])
	var ref_set: Dictionary = index_sets.get(target, {})
	if ref_set.has(value):
		return
	var target_meta: Dictionary = {}
	for t in schema.tables:
		if str(t["name"]) == target:
			target_meta = t
			break
	var hint := ""
	if not target_meta.is_empty():
		if bool(schema.beans.get(str(target_meta["bean_name"]), {}).get("abstract", false)):
			hint = "（目标表为多态表，请确认 id 是否在具体子类型中）"
	issues.append(CFIssue.make(CFIssue.ERROR, "E_REF_MISSING",
		"字段 %s=%s 引用的记录不存在（表 %s 的 %s 中无此值）%s"
		% [str(field["name"]), str(value), target, str(target_meta.get("index", "")), hint], ctx))


## 枚举值域：数值必须在枚举的取值集合里。
static func _check_enum(schema: CFSchema, field: Dictionary, value: Variant, ctx: Dictionary, issues: Array) -> void:
	var enum_name := str(field["info"].get("type", ""))
	if not schema.enums.has(enum_name):
		return
	var values: Dictionary = schema.enums[enum_name]["values"]
	if values.values().has(value):
		return
	issues.append(CFIssue.make(CFIssue.ERROR, "E_ENUM_VALUE",
		"字段 %s 的枚举 %s 无取值 %s" % [str(field["name"]), enum_name, str(value)], ctx))


## 标量叶子的约束：数值范围 / 字符串长度 / 正则 / 资源路径。
static func _check_leaf(schema: CFSchema, field: Dictionary, value: Variant, ctx: Dictionary, path_cache: Dictionary, issues: Array) -> void:
	var fname := str(field["name"])
	var info: Dictionary = field["info"]

	# 数值范围
	if CFTypeSystem.is_numeric(info):
		var num: Variant = _to_number(value)
		if num != null:
			var min_v: Variant = field["min"]
			var max_v: Variant = field["max"]
			if min_v != null:
				var mn: Variant = _to_number(min_v)
				if mn != null and float(num) < float(mn):
					issues.append(CFIssue.make(CFIssue.ERROR, "E_RANGE_MIN",
						"字段 %s=%s 小于最小值 %s" % [fname, str(value), str(min_v)], ctx))
			if max_v != null:
				var mx: Variant = _to_number(max_v)
				if mx != null and float(num) > float(mx):
					issues.append(CFIssue.make(CFIssue.ERROR, "E_RANGE_MAX",
						"字段 %s=%s 大于最大值 %s" % [fname, str(value), str(max_v)], ctx))

	# 字符串长度与正则
	if value is String:
		var text := str(value)
		var len_min := int(field["len_min"])
		var len_max := int(field["len_max"])
		var length := text.length()
		if len_min > 0 and length < len_min:
			issues.append(CFIssue.make(CFIssue.ERROR, "E_LEN_MIN",
				"字段 %s 长度 %d 小于下限 %d" % [fname, length, len_min], ctx))
		if len_max > 0 and length > len_max:
			issues.append(CFIssue.make(CFIssue.ERROR, "E_LEN_MAX",
				"字段 %s 长度 %d 大于上限 %d" % [fname, length, len_max], ctx))
		var pattern := str(field["pattern"])
		if pattern != "":
			var re := RegEx.new()
			if re.compile(pattern) == OK:
				if re.search(text) == null:
					issues.append(CFIssue.make(CFIssue.ERROR, "E_PATTERN",
						"字段 %s=%s 不匹配格式 %s" % [fname, text, pattern], ctx))

	# 资源路径
	var prefix := str(field["path"])
	if prefix != "" and value is String:
		_check_path(fname, prefix, str(value), ctx, path_cache, issues)


## 资源路径校验：相对值拼上前缀，绝对值原样查；结果按完整路径缓存，避免重复读盘。
static func _check_path(fname: String, prefix: String, value: String, ctx: Dictionary, path_cache: Dictionary, issues: Array) -> void:
	var target := value.strip_edges()
	if target == "":
		return
	var full := target
	if not (target.begins_with("res://") or target.begins_with("user://") or target.is_absolute_path()):
		var dir := prefix
		if dir == "*":
			dir = "res://"
		if not dir.ends_with("/"):
			dir += "/"
		full = dir + target
	if not path_cache.has(full):
		path_cache[full] = _resource_exists(full)
	if bool(path_cache[full]):
		return
	issues.append(CFIssue.make(CFIssue.ERROR, "E_PATH_MISSING",
		"字段 %s 的资源路径不存在：%s" % [fname, full], ctx))


## 路径存在性：文件/目录/可加载资源任一成立就算存在；带通配符时只要求所在目录存在。
static func _resource_exists(path: String) -> bool:
	if path.contains("*"):
		# 通配路径只要求目录存在
		var dir := path.get_base_dir()
		return DirAccess.dir_exists_absolute(dir)
	if FileAccess.file_exists(path):
		return true
	if DirAccess.dir_exists_absolute(path):
		return true
	return ResourceLoader.exists(path)


# ---------------------------------------------------------------- 未使用类型

## 死配置提示：没有被任何表/字段用到的结构、枚举各报一条 warning。
static func _collect_unused(schema: CFSchema, issues: Array) -> void:
	var used_beans: Dictionary = {}
	var used_enums: Dictionary = {}
	for t in schema.tables:
		used_beans[str(t["bean_name"])] = true
		var idx := schema.index_field(t)
		if not idx.is_empty():
			_mark_used(idx["info"], used_beans, used_enums)
	for bname in schema.beans.keys():
		for f in schema.beans[bname]["fields"]:
			_mark_used(f["info"], used_beans, used_enums)
	# 父类链与多态基类：被用到就顺带算上它的父类/子类型集合
	var pending: Array = used_beans.keys()
	while not pending.is_empty():
		var name := str(pending.pop_back())
		if not schema.beans.has(name):
			continue
		var parent := str(schema.beans[name]["parent"])
		if parent != "" and not used_beans.has(parent):
			used_beans[parent] = true
			pending.append(parent)
	for bname in schema.beans.keys():
		var def: Dictionary = schema.beans[bname]
		if used_beans.has(bname):
			for v in def["variants"]:
				if not used_beans.has(str(v)):
					used_beans[str(v)] = true
	for bname in schema.beans.keys():
		if not used_beans.has(bname):
			issues.append(CFIssue.make(CFIssue.WARNING, WARN_UNUSED_BEAN,
				"结构 %s 没有被任何表或字段使用" % bname, {"field": bname}))
	for ename in schema.enums.keys():
		if not used_enums.has(ename):
			issues.append(CFIssue.make(CFIssue.WARNING, WARN_UNUSED_ENUM,
				"枚举 %s 没有被任何字段使用" % ename, {"field": ename}))


## 把某个字段类型用到的枚举/结构标记为「已使用」，容器类型递归下去。
static func _mark_used(info: Dictionary, used_beans: Dictionary, used_enums: Dictionary) -> void:
	match str(info.get("kind", "")):
		"enum":
			used_enums[str(info.get("type", ""))] = true
		"bean":
			used_beans[str(info.get("type", ""))] = true
		"list":
			_mark_used(info.get("elem", {}), used_beans, used_enums)
		"map":
			_mark_used(info.get("key", {}), used_beans, used_enums)
			_mark_used(info.get("value", {}), used_beans, used_enums)


# ---------------------------------------------------------------- 小工具

## 宽松取数：能当数字用的（int/float/数字字符串）返回 float，否则 null。
static func _to_number(value: Variant) -> Variant:
	if value is int or value is float:
		return float(value)
	if value is bool:
		return null
	if value is String:
		var s := str(value).strip_edges()
		if s.is_valid_float():
			return float(s)
	return null
