@tool
class_name CFSchema
extends RefCounted

## 配置工坊 · 结构定义（schema.json）
##
## 把 Luban 的「类型系统」落在 JSON 上：enums / beans / tables 三段。
## 相比只支持「表头」的配置工具，这里补上了结构嵌套、继承与多态：
##
##   beans[]  每个结构可声明 parent（继承，字段合并）、abstract（抽象，
##            不能直接建表）、variants（多态子类型清单，按 $type 字段分派）。
##   tables[] 每张表声明 bean / input / index / mode / group。
##
## 归一化产物（供加载、校验、生成、UI 共用）：
##   enums[名]  = { name, comment, values{名:值}, order[名] }
##   beans[名]  = { name, parent, abstract, comment, variants[], own_fields[], fields[] }
##   tables[]   = { name, bean_name, bean, input, file_name, source, mode, index,
##                  group, comment, file_stem, member }
## 字段归一化产物见 _make_field()。

const SCHEMA_FORMAT := "configforge/1"

var enums: Dictionary = {}
var beans: Dictionary = {}
var tables: Array = []
var issues: Array = []
var raw: Dictionary = {}
var source_path := ""
var version := 1


# ---------------------------------------------------------------- 生命周期

## 清空解析结果（保留 source_path）。
func reset() -> void:
	enums = {}
	beans = {}
	tables = []
	issues = []
	raw = {}
	version = 1


## 从文件加载并解析。返回是否没有任何 error。
func load_from_file(path: String) -> bool:
	source_path = path
	if not FileAccess.file_exists(path):
		add_error("E_SCHEMA_MISSING", "找不到结构文件：%s" % path, {"file": path})
		return false
	var text := FileAccess.get_file_as_string(path)
	var data: Variant = JSON.parse_string(text)
	if data == null:
		add_error("E_SCHEMA_JSON", "结构文件不是合法 JSON：%s" % path, {"file": path})
		return false
	if not (data is Dictionary):
		add_error("E_SCHEMA_ROOT", "结构文件根节点必须是对象：%s" % path, {"file": path})
		return false
	return parse(data)


## 解析结构字典（raw 可直接来自 JSON.parse_string，也可来自 UI 编辑）。
func parse(data: Dictionary) -> bool:
	reset()
	raw = data
	version = _int(data.get("version", 1))
	_parse_enums(data.get("enums", []))
	_parse_beans(data.get("beans", []))
	_parse_tables(data.get("tables", []))
	# 表级引用检查放在最后：需要所有表都登记完才能判断 ref 指向是否存在
	_check_schema_refs()
	if tables.is_empty():
		add_warning("W_NO_TABLES", "结构里没有定义任何表（tables 为空），生成产物将只有空壳")
	return not has_errors()


## 用当前 raw 重新解析一次。
## UI 在结构页增删字段后调用它，让 beans / tables 立刻反映改动（否则 bean_field 查不到新字段，
## 树里会「看不到刚加的字段」；数据页的列也要等它刷新）。
## 注意：parse() 内部会先 reset()，但参数 data 持有的是原字典的引用，所以传 raw 是安全的。
func reparse() -> bool:
	return parse(raw)


## 写回结构文件（raw 的当前内容）。
func save_to_file(path: String) -> bool:
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		DirAccess.make_dir_recursive_absolute(dir)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		add_error("E_SCHEMA_WRITE", "无法写入结构文件：%s" % path, {"file": path})
		return false
	file.store_string(JSON.stringify(raw, "\t", false) + "\n")
	file.close()
	source_path = path
	return true


# ---------------------------------------------------------------- 问题收集

func add_error(code: String, message: String, opts: Dictionary = {}) -> void:
	issues.append(CFIssue.make(CFIssue.ERROR, code, message, opts))


func add_warning(code: String, message: String, opts: Dictionary = {}) -> void:
	issues.append(CFIssue.make(CFIssue.WARNING, code, message, opts))


func has_errors() -> bool:
	return CFIssue.count_errors(issues) > 0


func error_count() -> int:
	return CFIssue.count_errors(issues)


func warning_count() -> int:
	return CFIssue.count_warnings(issues)


# ---------------------------------------------------------------- 枚举

func _parse_enums(node: Variant) -> void:
	if node == null:
		return
	if not (node is Array):
		add_error("E_ENUMS_TYPE", "enums 必须是数组")
		return
	for e in node:
		if not (e is Dictionary):
			add_error("E_ENUM_DEF", "enums 的每一项必须是对象")
			continue
		var ename := str(e.get("name", "")).strip_edges()
		if ename == "":
			add_error("E_ENUM_NAME", "存在缺少 name 的枚举")
			continue
		if enums.has(ename):
			add_error("E_ENUM_DUPLICATE", "枚举 %s 重复定义" % ename)
			continue
		if not is_symbol_ok(ename):
			add_error("E_ENUM_IDENT", "枚举名 %s 不是合法的 GDScript 标识符（不能做生成代码里的 enum 名）" % ename)
			continue
		var values: Dictionary = {}
		var aliases: Dictionary = {}
		var order: Array = []
		var vnode: Variant = e.get("values", [])
		if vnode is Dictionary:
			for k in vnode.keys():
				var vname := str(k).strip_edges()
				if vname == "":
					add_error("E_ENUM_VALUE_NAME", "枚举 %s 存在空的取值名" % ename)
					continue
				if not is_symbol_ok(vname):
					add_error("E_ENUM_VALUE_IDENT", "枚举 %s 的取值名 %s 不是合法的 GDScript 标识符" % [ename, vname])
					continue
				values[vname] = _int(vnode[k])
				order.append(vname)
		elif vnode is Array:
			var used_values: Dictionary = {}
			for v in vnode:
				if not (v is Dictionary):
					add_error("E_ENUM_VALUE_DEF", "枚举 %s 的 values 每一项必须是对象" % ename)
					continue
				var vname := str(v.get("name", "")).strip_edges()
				if vname == "":
					add_error("E_ENUM_VALUE_NAME", "枚举 %s 存在空的取值名" % ename)
					continue
				if not is_symbol_ok(vname):
					add_error("E_ENUM_VALUE_IDENT", "枚举 %s 的取值名 %s 不是合法的 GDScript 标识符" % [ename, vname])
					continue
				if values.has(vname):
					add_error("E_ENUM_VALUE_DUP", "枚举 %s 的取值名 %s 重复" % [ename, vname])
					continue
				var vval := _int(v.get("value", 0))
				if used_values.has(vval):
					add_warning("W_ENUM_VALUE_SAME", "枚举 %s 的取值 %d 被 %s 与 %s 共用" % [ename, vval, str(used_values[vval]), vname])
				used_values[vval] = vname
				values[vname] = vval
				order.append(vname)
				# alias 让策划能填中文别名（编辑器单元格与 CSV 都认）
				var alias := str(v.get("alias", "")).strip_edges()
				if alias != "":
					if aliases.has(alias):
						add_warning("W_ENUM_ALIAS_DUP", "枚举 %s 的别名 %s 重复" % [ename, alias])
					aliases[alias] = vval
		else:
			add_error("E_ENUM_VALUES", "枚举 %s 的 values 必须是数组或对象" % ename)
			continue
		if values.is_empty():
			add_warning("W_ENUM_EMPTY", "枚举 %s 没有任何取值" % ename)
		enums[ename] = {
			"name": ename,
			"comment": str(e.get("comment", e.get("desc", ""))),
			"values": values,
			"aliases": aliases,
			"order": order,
		}


## 枚举数值 → 取值名；未知返回 ""。
func enum_name_of(enum_name: String, value: Variant) -> String:
	if not enums.has(enum_name):
		return ""
	var values: Dictionary = enums[enum_name]["values"]
	for k in values.keys():
		if values[k] == value:
			return str(k)
	return ""


# ---------------------------------------------------------------- 结构

func _parse_beans(node: Variant) -> void:
	if node == null:
		return
	if not (node is Array):
		add_error("E_BEANS_TYPE", "beans 必须是数组")
		return

	# 第一遍：登记全部结构名（后续断类型需要完整名单，允许前向引用）
	for b in node:
		if not (b is Dictionary):
			add_error("E_BEAN_DEF", "beans 的每一项必须是对象")
			continue
		var bname := str(b.get("name", "")).strip_edges()
		if bname == "":
			add_error("E_BEAN_NAME", "存在缺少 name 的结构定义")
			continue
		if beans.has(bname):
			add_error("E_BEAN_DUPLICATE", "结构 %s 重复定义" % bname)
			continue
		if not is_symbol_ok(bname):
			add_error("E_BEAN_IDENT", "结构名 %s 不是合法的 GDScript 标识符" % bname)
			continue
		var parent := str(b.get("parent", "")).strip_edges()
		beans[bname] = {
			"name": bname,
			"parent": parent,
			"abstract": bool(b.get("abstract", false)),
			"comment": str(b.get("comment", b.get("desc", ""))),
			"variants": [],
			"own_fields": [],
			"fields": [],
			"resolved": false,
			"raw_fields": b.get("fields", []),
			"raw_variants": b.get("variants", []),
		}

	# 第二遍：解析自身字段（此时枚举与结构名都齐了，可判类型）
	for bname in beans.keys():
		var def: Dictionary = beans[bname]
		def["own_fields"] = _parse_fields(bname, def["raw_fields"])
		var variants: Array = []
		var rv: Variant = def["raw_variants"]
		if rv is Array:
			for v in rv:
				var vn := str(v).strip_edges()
				if vn != "" and not variants.has(vn):
					variants.append(vn)
		elif rv != null:
			add_error("E_BEAN_VARIANTS", "结构 %s 的 variants 必须是数组" % bname, {"field": bname})
		def["variants"] = variants

	# 第三遍：继承展开（父类字段在前，子类同名字段覆盖）
	for bname in beans.keys():
		_resolve_fields(bname, [])

	# 第四遍：校验父类存在性、由子类反推 variants
	for bname in beans.keys():
		var def: Dictionary = beans[bname]
		var parent := str(def["parent"])
		if parent == "":
			continue
		if not beans.has(parent):
			add_error("E_BEAN_PARENT", "结构 %s 的父类 %s 不存在" % [bname, parent], {"field": bname})
			def["parent"] = ""
			continue
		var pvariants: Array = beans[parent]["variants"]
		if not pvariants.has(bname):
			pvariants.append(bname)
		if bool(def["abstract"]) and not bool(beans[parent]["abstract"]):
			add_warning("W_BEAN_ABSTRACT_CHILD", "结构 %s 是抽象类，但父类 %s 不是抽象类" % [bname, parent], {"field": bname})

	# 第五遍：variants 必须存在且真的是子类型
	for bname in beans.keys():
		var def: Dictionary = beans[bname]
		var variants: Array = def["variants"]
		for vn in variants:
			if not beans.has(vn):
				add_error("E_BEAN_VARIANT_MISSING", "结构 %s 声明的子类型 %s 不存在" % [bname, vn], {"field": bname})
				continue
			var child: Dictionary = beans[vn]
			if str(child["parent"]) != bname:
				add_warning("W_BEAN_VARIANT_PARENT", "结构 %s 声明子类型 %s，但它并未继承 %s" % [bname, vn, bname], {"field": bname})
		# 多态基类的字段布局会被子类共享，不强制 abstract
		if not variants.is_empty():
			def["polymorphic"] = true
		else:
			def["polymorphic"] = false

	# 清理内部临时字段
	for bname in beans.keys():
		var def: Dictionary = beans[bname]
		def.erase("raw_fields")
		def.erase("raw_variants")
		def.erase("resolved")
		if not def.has("polymorphic"):
			def["polymorphic"] = false


## 解析一个结构的自身字段数组。
func _parse_fields(bean_name: String, node: Variant) -> Array:
	var out: Array = []
	if node == null:
		return out
	if not (node is Array):
		add_error("E_BEAN_FIELDS", "结构 %s 的 fields 必须是数组" % bean_name, {"field": bean_name})
		return out
	var names: Dictionary = {}
	for f in node:
		if not (f is Dictionary):
			add_error("E_FIELD_DEF", "结构 %s 存在非对象的字段定义" % bean_name, {"field": bean_name})
			continue
		var fname := str(f.get("name", "")).strip_edges()
		if fname == "":
			add_error("E_FIELD_NAME", "结构 %s 存在缺少 name 的字段" % bean_name, {"field": bean_name})
			continue
		if not is_symbol_ok(fname):
			add_error("E_FIELD_IDENT", "结构 %s 的字段名 %s 不是合法的 GDScript 标识符" % [bean_name, fname], {"field": fname})
			continue
		if RESERVED_MEMBERS.has(fname):
			add_error("E_FIELD_RESERVED", "结构 %s 的字段名 %s 与生成代码的内部成员同名，请改名" % [bean_name, fname], {"field": fname})
			continue
		if names.has(fname):
			add_error("E_FIELD_DUPLICATE", "结构 %s 的字段 %s 重复定义" % [bean_name, fname], {"field": fname})
			continue
		names[fname] = true
		var ftype := str(f.get("type", "")).strip_edges()
		if ftype == "":
			add_error("E_FIELD_TYPE", "结构 %s 的字段 %s 缺少 type" % [bean_name, fname], {"field": fname})
			continue
		var info := CFTypeSystem.parse_type(ftype, enums, beans)
		if not bool(info["ok"]):
			add_error("E_FIELD_TYPE", "结构 %s 的字段 %s：%s" % [bean_name, fname, str(info["error"])], {"field": fname})
			continue
		out.append(_make_field(f, fname, ftype, info))
	return out


## 字段归一化：类型信息 + 约束元数据，全部环节只看这个形状。
func _make_field(raw_field: Dictionary, fname: String, ftype: String, info: Dictionary) -> Dictionary:
	var sep := str(raw_field.get("sep", "|"))
	if sep == "":
		sep = "|"
	# required 默认值：数值 / 布尔 / 枚举默认必填（漏填要报出来），
	# 字符串与容器默认可不填（空串、空表是合法值）。显式写 required 以其为准。
	var required := true
	var kind := str(info["kind"])
	if kind == "scalar" and str(info["type"]) == "string":
		required = false
	elif kind == "list" or kind == "map" or kind == "bean":
		required = false
	if raw_field.has("required"):
		required = bool(raw_field["required"])
	var len_min := 0
	var len_max := 0
	if raw_field.has("len_min"):
		len_min = _int(raw_field["len_min"])
	if raw_field.has("len_max"):
		len_max = _int(raw_field["len_max"])
	if raw_field.has("len"):
		var lv: Variant = raw_field["len"]
		if lv is Array and lv.size() >= 1:
			len_min = _int(lv[0])
			if lv.size() >= 2:
				len_max = _int(lv[1])
		else:
			len_min = _int(lv)
			len_max = _int(lv)
	var pattern := str(raw_field.get("pattern", ""))
	if pattern != "":
		var re := RegEx.new()
		if re.compile(pattern) != OK:
			add_error("E_FIELD_PATTERN", "字段 %s 的正则 %s 无法编译" % [fname, pattern], {"field": fname})
			pattern = ""
	return {
		"name": fname,
		"type": ftype,
		"kind": str(info["kind"]),
		"info": info,
		"comment": str(raw_field.get("comment", raw_field.get("desc", ""))),
		"required": required,
		"sep": sep,
		"ref": str(raw_field.get("ref", "")).strip_edges(),
		"min": raw_field.get("min", null),
		"max": raw_field.get("max", null),
		"len_min": len_min,
		"len_max": len_max,
		"pattern": pattern,
		"path": str(raw_field.get("path", "")),
		"alias": str(raw_field.get("alias", "")),
	}


## 继承展开：父类字段在前，子类同名字段覆盖父类。结果缓存进 beans[name].fields。
func _resolve_fields(bean_name: String, stack: Array) -> Array:
	if not beans.has(bean_name):
		return []
	var def: Dictionary = beans[bean_name]
	if bool(def["resolved"]):
		return def["fields"]
	if stack.has(bean_name):
		add_error("E_BEAN_CYCLE", "结构继承成环：%s" % " → ".join(stack + [bean_name]), {"field": bean_name})
		def["resolved"] = true
		return []
	stack.append(bean_name)
	var merged: Array = []
	var parent := str(def["parent"])
	if parent != "":
		if beans.has(parent):
			merged = _resolve_fields(parent, stack).duplicate(true)
	for f in def["own_fields"]:
		var replaced := false
		for i in range(merged.size()):
			if str(merged[i]["name"]) == str(f["name"]):
				add_warning("W_FIELD_OVERRIDE",
					"结构 %s 的字段 %s 覆盖了父类 %s 的同名字段" % [bean_name, str(f["name"]), str(def["parent"])],
					{"field": str(f["name"])})
				merged[i] = f
				replaced = true
				break
		if not replaced:
			merged.append(f)
	def["fields"] = merged
	def["resolved"] = true
	stack.pop_back()
	return merged


# ---------------------------------------------------------------- 表

func _parse_tables(node: Variant) -> void:
	if node == null:
		return
	if not (node is Array):
		add_error("E_TABLES_TYPE", "tables 必须是数组")
		return
	var seen: Dictionary = {}
	var members: Dictionary = {}
	for t in node:
		if not (t is Dictionary):
			add_error("E_TABLE_DEF", "tables 的每一项必须是对象")
			continue
		var tname := str(t.get("name", "")).strip_edges()
		if tname == "":
			add_error("E_TABLE_NAME", "存在缺少 name 的表")
			continue
		if not is_symbol_ok(tname):
			add_error("E_TABLE_IDENT", "表名 %s 不是合法的 GDScript 标识符（会作为生成代码里的类名）" % tname)
			continue
		if seen.has(tname):
			add_error("E_TABLE_DUPLICATE", "表 %s 重复定义" % tname, {"table": tname})
			continue
		seen[tname] = true
		var bean_name := str(t.get("bean", "")).strip_edges()
		if bean_name == "":
			add_error("E_TABLE_BEAN", "表 %s 缺少 bean" % tname, {"table": tname})
			continue
		if not beans.has(bean_name):
			add_error("E_TABLE_BEAN", "表 %s 引用了不存在的结构 %s" % [tname, bean_name], {"table": tname})
			continue
		if bool(beans[bean_name]["abstract"]):
			add_error("E_TABLE_ABSTRACT", "表 %s 不能直接使用抽象结构 %s（请改用具体子类）" % [tname, bean_name], {"table": tname})
			continue
		if not beans[bean_name]["variants"].is_empty():
			add_error("E_TABLE_POLYMORPHIC", "表 %s 的 bean %s 是多态基类，请改用具体子类型（否则生成的代码只能拿到基类字段）" % [tname, bean_name], {"table": tname})
			continue
		var input := str(t.get("input", "")).strip_edges()
		if input == "":
			add_error("E_TABLE_INPUT", "表 %s 缺少 input（数据源文件）" % tname, {"table": tname})
			continue
		var src := detect_source(input)
		if str(src["source"]) == "":
			add_error("E_TABLE_INPUT", "表 %s 的数据源 %s 不受支持（仅支持 .csv / .tsv / .json）" % [tname, input], {"table": tname})
			continue
		var fields: Array = beans[bean_name]["fields"]
		var index := str(t.get("index", "")).strip_edges()
		if index == "":
			if has_field(fields, "id"):
				index = "id"
			elif not fields.is_empty():
				index = str(fields[0]["name"])
		elif not has_field(fields, index):
			add_error("E_TABLE_INDEX", "表 %s 的索引字段 %s 不在结构 %s 中" % [tname, index, bean_name], {"table": tname})
			index = ""
		var mode := str(t.get("mode", "")).strip_edges().to_lower()
		if mode == "":
			mode = "map" if index != "" else "list"
		if mode != "map" and mode != "list":
			add_error("E_TABLE_MODE", "表 %s 的 mode 只能是 map 或 list（实际 %s）" % [tname, mode], {"table": tname})
			mode = "map"
		var member := member_name(tname)
		if members.has(member):
			add_error("E_TABLE_MEMBER", "表 %s 与 %s 生成的成员名同为 %s" % [tname, str(members[member]), member], {"table": tname})
		members[member] = tname
		tables.append({
			"name": tname,
			"bean_name": bean_name,
			"bean": beans[bean_name],
			"input": input,
			"file_name": str(src["file"]),
			"source": str(src["source"]),
			"mode": mode,
			"index": index,
			"group": str(t.get("group", "")).strip_edges(),
			"comment": str(t.get("comment", t.get("desc", ""))),
			"file_stem": tname.to_lower(),
			"member": member,
		})


## 识别数据源：`*@x.json` 与 `x.json` 都是 JSON；.csv/.tsv 按分隔符切。
static func detect_source(input: String) -> Dictionary:
	var s := input.strip_edges()
	if s.begins_with("*@"):
		s = s.substr(2).strip_edges()
	var lower := s.to_lower()
	if lower.ends_with(".csv"):
		return {"source": "csv", "file": s}
	if lower.ends_with(".tsv"):
		return {"source": "tsv", "file": s}
	if lower.ends_with(".json"):
		return {"source": "json", "file": s}
	return {"source": "", "file": s}


## TbItem → tbItem（与 Luban gdscript 产物一致：Tb 前缀小写，其余保留）。
static func member_name(table_name: String) -> String:
	if table_name.begins_with("Tb") and table_name.length() > 2:
		return "tb" + table_name.substr(2)
	return table_name.to_lower()


func _check_schema_refs() -> void:
	var table_names: Dictionary = {}
	for t in tables:
		table_names[str(t["name"])] = true
	for bname in beans.keys():
		var def: Dictionary = beans[bname]
		# 只检查自身字段：继承来的字段已在其声明处检查过，避免重复报错
		for f in def["own_fields"]:
			var ref := str(f["ref"])
			if ref == "":
				continue
			if not table_names.has(ref):
				add_error("E_FIELD_REF", "结构 %s 字段 %s 的 ref 指向不存在的表 %s" % [bname, str(f["name"]), ref], {"field": str(f["name"])})
				continue
			var ref_table := table_by_name(ref)
			if ref_table.is_empty():
				continue
			if str(ref_table["index"]) == "":
				add_error("E_FIELD_REF_INDEX", "结构 %s 字段 %s 引用的表 %s 没有索引字段，无法做引用校验" % [bname, str(f["name"]), ref], {"field": str(f["name"])})
				continue
			var kind := str(f["kind"])
			if kind == "list" or kind == "map":
				var target_info: Dictionary = f["info"]["elem"] if kind == "list" else f["info"]["value"]
				var tk := str(target_info.get("kind", ""))
				if tk != "scalar" and tk != "enum":
					add_warning("W_FIELD_REF_CONTAINER", "结构 %s 字段 %s 是容器且带 ref，但元素不是标量/枚举，引用校验会被跳过" % [bname, str(f["name"])], {"field": str(f["name"])})
			elif kind != "scalar" and kind != "enum":
				add_warning("W_FIELD_REF_TYPE", "结构 %s 字段 %s 带 ref，但类型是 %s，引用校验会被跳过" % [bname, str(f["name"]), str(f["type"])], {"field": str(f["name"])})


# ---------------------------------------------------------------- 查询辅助

func has_field(fields: Array, field_name: String) -> bool:
	for f in fields:
		if str(f["name"]) == field_name:
			return true
	return false


## 取结构字段定义；不存在返回 {}。
func bean_field(bean_name: String, field_name: String) -> Dictionary:
	if not beans.has(bean_name):
		return {}
	for f in beans[bean_name]["fields"]:
		if str(f["name"]) == field_name:
			return f
	return {}


## 取表的索引字段定义；无索引返回 {}。
func index_field(table: Dictionary) -> Dictionary:
	var index := str(table.get("index", ""))
	if index == "":
		return {}
	return bean_field(str(table["bean_name"]), index)


func table_by_name(table_name: String) -> Dictionary:
	for t in tables:
		if str(t["name"]) == table_name:
			return t
	return {}


func table_names() -> Array:
	var out: Array = []
	for t in tables:
		out.append(str(t["name"]))
	return out


## 按 group 过滤表：group 为空或包含目标字符则保留（Luban 的 group 分组导出思路）。
func tables_for_group(group: String) -> Array:
	if group == "":
		return tables.duplicate()
	var out: Array = []
	for t in tables:
		var g := str(t.get("group", ""))
		if g == "" or g.contains(group):
			out.append(t)
	return out


## 原始 schema 里某个结构的字典（UI 结构页直接改它，再 save_to_file）。
func raw_bean(bean_name: String) -> Dictionary:
	var list: Variant = raw.get("beans", [])
	if not (list is Array):
		return {}
	for b in list:
		if b is Dictionary and str(b.get("name", "")) == bean_name:
			return b
	return {}


## 原始 schema 里某个枚举的字典（改完记得 reparse）。
func raw_enum(enum_name: String) -> Dictionary:
	var list: Variant = raw.get("enums", [])
	if not (list is Array):
		return {}
	for e in list:
		if e is Dictionary and str(e.get("name", "")) == enum_name:
			return e
	return {}


## 原始 schema 里某张表的字典（改完记得 reparse）。
func raw_table(table_name: String) -> Dictionary:
	var list: Variant = raw.get("tables", [])
	if not (list is Array):
		return {}
	for t in list:
		if t is Dictionary and str(t.get("name", "")) == table_name:
			return t
	return {}


# ---------------------------------------------------------------- UI 结构编辑
# 下面几个只改 raw，调用方改完必须 reparse() 才能让 beans / tables 反映改动。

## raw.enums 数组（不存在就建一个）。
func raw_enums_list() -> Array:
	var list: Variant = raw.get("enums", [])
	if not (list is Array):
		list = []
		raw["enums"] = list
	return list


## raw.tables 数组（不存在就建一个）。
func raw_tables_list() -> Array:
	var list: Variant = raw.get("tables", [])
	if not (list is Array):
		list = []
		raw["tables"] = list
	return list


## 新增一个枚举（默认带 Common = 1，避免空枚举解析出问题）。
func add_enum(enum_name: String, comment: String = "") -> bool:
	var clean := enum_name.strip_edges()
	if clean == "" or not raw_enum(clean).is_empty():
		return false
	raw_enums_list().append({
		"name": clean,
		"comment": comment,
		"values": [{"name": "Common", "value": 1}],
	})
	return true


## 删除一个枚举定义（调用方需先确认没有字段在用它）。
func remove_enum(enum_name: String) -> bool:
	var list := raw_enums_list()
	for i in range(list.size()):
		var e: Variant = list[i]
		if e is Dictionary and str(e.get("name", "")) == enum_name:
			list.remove_at(i)
			return true
	return false


## 新增一张表。input 是数据源文件名（决定 csv/json 与生成文件名）。
func add_table(table_name: String, bean: String, input: String, mode: String = "map", index_field: String = "id", group: String = "", comment: String = "") -> bool:
	var clean := table_name.strip_edges()
	if clean == "" or not raw_table(clean).is_empty():
		return false
	if bean.strip_edges() == "" or input.strip_edges() == "":
		return false
	raw_tables_list().append({
		"name": clean,
		"bean": bean.strip_edges(),
		"input": input.strip_edges(),
		"mode": mode,
		"index": index_field,
		"group": group,
		"comment": comment,
	})
	return true


## 删除一张表定义（调用方需先确认没有字段 ref 它）。
func remove_table(table_name: String) -> bool:
	var list := raw_tables_list()
	for i in range(list.size()):
		var t: Variant = list[i]
		if t is Dictionary and str(t.get("name", "")) == table_name:
			list.remove_at(i)
			return true
	return false


# ---------------------------------------------------------------- 出口

## 机器可读 schema（对应 Luban 的 `-c schema-json`）：给 AI Agent / 外部工具消费。
func to_agent_json() -> Dictionary:
	var out_enums: Array = []
	for ename in enums.keys():
		var e: Dictionary = enums[ename]
		var values: Array = []
		for vname in e["order"]:
			values.append({"name": str(vname), "value": int(e["values"][vname])})
		out_enums.append({"name": ename, "comment": str(e["comment"]), "values": values})

	var out_beans: Array = []
	for bname in beans.keys():
		var b: Dictionary = beans[bname]
		var fields: Array = []
		for f in b["fields"]:
			fields.append({
				"name": str(f["name"]),
				"type": str(f["type"]),
				"kind": str(f["kind"]),
				"comment": str(f["comment"]),
				"required": bool(f["required"]),
				"nullable": bool(f["info"].get("nullable", false)),
				"sep": str(f["sep"]),
				"ref": str(f["ref"]),
				"min": f["min"],
				"max": f["max"],
				"len_min": int(f["len_min"]),
				"len_max": int(f["len_max"]),
				"pattern": str(f["pattern"]),
				"path": str(f["path"]),
			})
		out_beans.append({
			"name": bname,
			"parent": str(b["parent"]),
			"abstract": bool(b["abstract"]),
			"polymorphic": bool(b["polymorphic"]),
			"comment": str(b["comment"]),
			"variants": b["variants"].duplicate(),
			"fields": fields,
		})

	var out_tables: Array = []
	for t in tables:
		out_tables.append({
			"name": str(t["name"]),
			"bean": str(t["bean_name"]),
			"input": str(t["input"]),
			"file": str(t["file_name"]),
			"source": str(t["source"]),
			"mode": str(t["mode"]),
			"index": str(t["index"]),
			"group": str(t["group"]),
			"comment": str(t["comment"]),
			"member": str(t["member"]),
			"data_file": str(t["file_stem"]) + ".json",
		})

	return {
		"format": SCHEMA_FORMAT,
		"version": version,
		"source": source_path,
		"enums": out_enums,
		"beans": out_beans,
		"tables": out_tables,
	}


# ---------------------------------------------------------------- 小工具

## GDScript 保留字：结构名/字段名/枚举取值名会原样进生成代码，撞上就是解析错误。
const GDSCRIPT_KEYWORDS := [
	"and", "as", "assert", "await", "break", "breakpoint", "class", "class_name",
	"const", "continue", "elif", "else", "enum", "extends", "false", "for", "func",
	"if", "in", "is", "match", "namespace", "not", "null", "or", "pass", "prelude",
	"return", "self", "signal", "static", "super", "trait", "true", "var", "void",
	"while", "yield",
]

## 生成代码里由模板占用的成员名：字段再叫这些名字就会「成员重复声明」。
const RESERVED_MEMBERS := ["_data", "__type_id__", "get_data", "get_type_id", "_init", "new"]


## 名字能否安全地贴进生成代码（合法标识符且不是保留字）。
static func is_symbol_ok(text: String) -> bool:
	if text == "":
		return false
	if not text.is_valid_identifier():
		return false
	return not GDSCRIPT_KEYWORDS.has(text.to_lower())


static func _int(v: Variant) -> int:
	if v is int:
		return v
	if v is bool:
		return 1 if v else 0
	if v is float:
		return int(v)
	var s := str(v).strip_edges()
	if s.is_valid_int():
		return int(s)
	if s.is_valid_float():
		return int(float(s))
	return 0
