@tool
class_name CFDataLoader
extends RefCounted

## 配置工坊 · 数据加载与类型化
##
## 把 CSV / TSV / JSON 源文件读成「类型化记录」（普通 Dictionary，字段值已按 schema 转换），
## 坏值与缺字段一律**保留占位**并记一条结构化问题，避免坏数据静默落盘：
## 编辑器里能看见这一行、能手工修，校验能指出问题，生成会被拦住。
##
## 表数据形状：
##   { name: { records: Array[Dictionary], lines: Array[int], file: String, issues: Array } }

const TYPE_INT := "int"
const TYPE_FLOAT := "float"
const TYPE_BOOL := "bool"
const TYPE_STRING := "string"


# ---------------------------------------------------------------- 批量加载

## 加载全部表。返回 { ok, tables: {表名: 表数据}, issues: Array }。
static func load_all(schema: CFSchema, data_dir: String) -> Dictionary:
	var tables: Dictionary = {}
	var issues: Array = []
	for table in schema.tables:
		var loaded := load_table(schema, table, data_dir)
		tables[str(table["name"])] = loaded
		issues.append_array(loaded["issues"])
	return {"ok": CFIssue.count_errors(issues) == 0, "tables": tables, "issues": issues}


## 加载单表。
static func load_table(schema: CFSchema, table: Dictionary, data_dir: String) -> Dictionary:
	var path := join_path(data_dir, str(table["file_name"]))
	if not FileAccess.file_exists(path):
		return _empty_result(path, CFIssue.make(CFIssue.ERROR, "E_DATA_MISSING",
			"找不到数据文件：%s" % path, {"table": str(table["name"]), "file": path}))
	var text := FileAccess.get_file_as_string(path)
	if str(table["source"]) == "json":
		var parsed: Variant = JSON.parse_string(CFCsv.strip_bom(text))
		if parsed == null:
			return _empty_result(path, CFIssue.make(CFIssue.ERROR, "E_DATA_JSON",
				"数据文件不是合法 JSON：%s" % path, {"table": str(table["name"]), "file": path}))
		return parse_json_records(schema, table, parsed, path)
	return parse_csv_text(schema, table, text, path)


## 从 CSV 文本解析（导入 / 从磁盘加载共用）。
## sep 留空时按表自己的数据源文件后缀推断；导入外部文件时应传入该文件的后缀。
static func parse_csv_text(schema: CFSchema, table: Dictionary, text: String, path: String = "", sep: String = "") -> Dictionary:
	var use_sep := sep
	if use_sep == "":
		use_sep = CFCsv.sep_for_file(str(table["file_name"]))
	var rows := CFCsv.parse(text, use_sep)
	return _convert_csv_rows(schema, table, rows, path)


## 从 JSON 根节点解析（导入 / 从磁盘加载共用）。根必须是对象数组。
static func parse_json_records(schema: CFSchema, table: Dictionary, parsed: Variant, path: String = "") -> Dictionary:
	var issues: Array = []
	if not (parsed is Array):
		issues.append(CFIssue.make(CFIssue.ERROR, "E_DATA_JSON_ROOT",
			"JSON 数据源根节点必须是数组（每条记录一个对象）", {"table": str(table["name"]), "file": path}))
		return {"name": str(table["name"]), "records": [], "lines": [], "file": path, "issues": issues}
	var records: Array = []
	var lines: Array = []
	for i in range(parsed.size()):
		var raw_rec: Variant = parsed[i]
		var row := i + 1
		if not (raw_rec is Dictionary):
			issues.append(CFIssue.make(CFIssue.ERROR, "E_DATA_RECORD",
				"记录必须是对象", {"table": str(table["name"]), "row": row, "file": path}))
			continue
		var conv := convert_record(schema, str(table["bean_name"]), raw_rec, {"table": str(table["name"]), "row": row, "file": path})
		records.append(conv["record"])
		lines.append(row)
		issues.append_array(conv["issues"])
	return {"name": str(table["name"]), "records": records, "lines": lines, "file": path, "issues": issues}


# ---------------------------------------------------------------- CSV 表头

## CSV 行 → 类型化记录。支持 Luban 风格的多行表头：
##   ##var     字段名行（首格为 ## 或 ##var）
##   ##type    类型行（仅作文档，类型以 schema 为准）
##   ##comment 说明行（仅作文档）
##   ##group   分组行（仅作文档）
## 字段名单元格可带 #sep=| / #ref=TbItem 之类的注释，解析时只取 # 之前的名字。
static func _convert_csv_rows(schema: CFSchema, table: Dictionary, rows: Array, path: String) -> Dictionary:
	var tname := str(table["name"])
	var issues: Array = []
	var fields: Array = table["bean"]["fields"]
	var column_map: Dictionary = {}
	var header_row := -1
	for r in range(rows.size()):
		var row: Array = rows[r]
		if row.is_empty():
			continue
		var first := str(row[0]).strip_edges()
		if first.begins_with("##"):
			var directive := first.substr(2).strip_edges().to_lower()
			if directive == "" or directive == "var" or directive == "name" or directive == "field":
				if header_row < 0:
					header_row = r
					for c in range(1, row.size()):
						var name := _cell_field_name(str(row[c]))
						if name != "":
							column_map[name] = c
			continue
		if first.begins_with("#"):
			continue  # 注释行
	var data_start := 0
	if header_row >= 0:
		data_start = header_row + 1
	else:
		# 没有 ##var 表头：兼容两种常见来源
		#   1) 第一行就是列名（Excel / 数据库导出）
		#   2) 完全没有表头 → 按 schema 的字段顺序取列
		var plain := _plain_header_map(rows, fields)
		if not plain.is_empty():
			column_map = plain
			data_start = 1
			issues.append(CFIssue.make(CFIssue.WARNING, "W_CSV_PLAIN_HEADER",
				"没有 ##var 表头，已按第一行的列名匹配字段", {"table": tname, "file": path}))
		else:
			# 数据行可能带「首列为空」的行号列，按列数判断要不要跳过它
			var offset := 0
			if rows.size() > 0:
				var row0: Array = rows[0]
				if row0.size() == fields.size() + 1:
					offset = 1
			for i in range(fields.size()):
				column_map[str(fields[i]["name"])] = i + offset
			data_start = 0
			issues.append(CFIssue.make(CFIssue.WARNING, "W_CSV_NO_HEADER",
				"没有找到表头，已按结构字段顺序解析（共 %d 列）" % fields.size(),
				{"table": tname, "file": path}))

	# 表头里有、结构里没有的列：大概率是拼错，报一次 warning（表级）
	var known: Dictionary = {}
	for f in fields:
		known[str(f["name"])] = true
	for col_name in column_map.keys():
		if not known.has(col_name):
			issues.append(CFIssue.make(CFIssue.WARNING, "W_CSV_UNKNOWN_COLUMN",
				"列 %s 不在结构 %s 中，已被忽略" % [str(col_name), str(table["bean_name"])],
				{"table": tname, "field": str(col_name), "file": path}))

	var records: Array = []
	var lines: Array = []
	for r in range(data_start, rows.size()):
		var row: Array = rows[r]
		if _is_blank_row(row):
			continue
		if str(row[0]).strip_edges().begins_with("#"):
			continue  # 没有表头的文件里也可能有注释行
		var row_no := r + 1
		var rec: Dictionary = {}
		var row_ctx := {"table": tname, "row": records.size() + 1, "file": path}
		for f in fields:
			var fname := str(f["name"])
			var col: int = int(column_map.get(fname, -1))
			var cell: Variant = ""
			if col >= 0 and col < row.size():
				cell = row[col]
			var field_ctx := {"table": tname, "row": row_ctx["row"], "field": fname, "file": path}
			if col < 0:
				issues.append(CFIssue.make(CFIssue.ERROR, "E_FIELD_MISSING_COLUMN",
					"缺少字段列 %s" % fname, field_ctx))
				rec[fname] = default_of(schema, f)
				continue
			var conv := convert_value(schema, f, cell, field_ctx)
			if conv["issue"] != null:
				issues.append(conv["issue"])
			rec[fname] = conv["value"]
		records.append(rec)
		lines.append(row_no)

	# bean 字段在 CSV 单元格里无法表达（map 可以用 k:v|k:v 写），提前说明，免得用户以为工具坏了
	for f in fields:
		if str(f["kind"]) == "bean":
			issues.append(CFIssue.make(CFIssue.WARNING, "W_CSV_UNSUPPORTED_TYPE",
				"字段 %s 的类型 %s 无法在 CSV 单元格中表达，本表建议改用 JSON 数据源" % [str(f["name"]), str(f["type"])],
				{"table": tname, "field": str(f["name"]), "file": path}))
	return {"name": tname, "records": records, "lines": lines, "file": path, "issues": issues}


## 把第一行当成「纯列名」试试：只有它覆盖了全部字段名时才认，避免把数据行误判成表头。
static func _plain_header_map(rows: Array, fields: Array) -> Dictionary:
	if rows.is_empty():
		return {}
	var first: Array = rows[0]
	var map: Dictionary = {}
	for c in range(first.size()):
		var name := _cell_field_name(str(first[c]))
		if name != "":
			map[name] = c
	if map.is_empty():
		return {}
	for f in fields:
		if not map.has(str(f["name"])):
			return {}
	return map


## 取字段名单元格中 # 之前的部分。
static func _cell_field_name(cell: String) -> String:
	var s := cell.strip_edges()
	var idx := s.find("#")
	if idx >= 0:
		return s.substr(0, idx).strip_edges()
	return s


static func _is_blank_row(row: Array) -> bool:
	for c in row:
		if str(c).strip_edges() != "":
			return false
	return true


# ---------------------------------------------------------------- 记录级类型化

## 把一条原始记录（Dictionary，来自 JSON）按结构类型化。
## 返回 { record: Dictionary, issues: Array }；坏字段用默认值占位，记录始终产出。
static func convert_record(schema: CFSchema, bean_name: String, raw: Dictionary, base_ctx: Dictionary) -> Dictionary:
	var issues: Array = []
	var rec: Dictionary = {}
	# 多态分派失败的原因要能带回调用方：借一个 sink 收集 _concrete_bean 报的问题
	var sink: Array = []
	var dispatch_ctx := base_ctx.duplicate(true)
	dispatch_ctx["_sink"] = sink
	var bean := _concrete_bean(schema, bean_name, raw, dispatch_ctx)
	issues.append_array(sink)
	if bean.is_empty():
		return {"record": rec, "issues": issues}
	var concrete := str(bean["name"])
	if concrete != bean_name:
		rec["$type"] = concrete
		if raw.has("$type"):
			var declared := str(raw["$type"])
			if declared != concrete:
				issues.append(CFIssue.make(CFIssue.ERROR, "E_BEAN_TYPE_MISMATCH",
					"$type 声明为 %s，但解析结果为 %s" % [declared, concrete], base_ctx))
	var fields: Array = bean["fields"]
	for f in fields:
		var fname := str(f["name"])
		var ctx := {"table": str(base_ctx.get("table", "")), "row": base_ctx.get("row", 0), "field": fname, "file": str(base_ctx.get("file", ""))}
		if not raw.has(fname):
			if bool(f["required"]):
				issues.append(CFIssue.make(CFIssue.ERROR, "E_FIELD_REQUIRED",
					"缺少必填字段 %s" % fname, ctx))
			rec[fname] = default_of(schema, f)
			continue
		var conv := convert_value(schema, f, raw[fname], ctx)
		if conv["issue"] != null:
			issues.append(conv["issue"])
		rec[fname] = conv["value"]
	# 结构里没声明的键：多半是拼写错误，报 warning 帮定位（$type 是保留键）
	for key in raw.keys():
		if str(key) == "$type":
			continue
		if not schema.has_field(fields, str(key)):
			issues.append(CFIssue.make(CFIssue.WARNING, "W_FIELD_UNKNOWN",
				"字段 %s 不在结构 %s 中，已忽略" % [str(key), concrete], base_ctx))
	return {"record": rec, "issues": issues}


## 解析多态结构的实际类型：带 $type 时按子类型名分派，否则用声明类型。
static func _concrete_bean(schema: CFSchema, bean_name: String, raw: Dictionary, ctx: Dictionary) -> Dictionary:
	if not schema.beans.has(bean_name):
		return {}
	var declared: Dictionary = schema.beans[bean_name]
	var variants: Array = declared.get("variants", [])
	if variants.is_empty():
		return declared
	var tag := str(raw.get("$type", "")).strip_edges()
	if tag == "":
		if bool(declared["abstract"]):
			_reject(ctx, CFIssue.ERROR, "E_BEAN_NO_TYPE",
				"结构 %s 是多态基类，记录必须带 $type 字段（可选：%s）" % [bean_name, str(variants)])
			return {}
		return declared
	if not schema.beans.has(tag):
		_reject(ctx, CFIssue.ERROR, "E_BEAN_UNKNOWN_TYPE",
			"$type=%s 不是已定义的结构" % tag)
		return {}
	if not variants.has(tag):
		_reject(ctx, CFIssue.ERROR, "E_BEAN_NOT_VARIANT",
			"$type=%s 不是 %s 的子类型（可选：%s）" % [tag, bean_name, str(variants)])
		return {}
	return schema.beans[tag]


# 结构分派错误需要在具体调用处报，这里借一个可变容器把问题带回去。
static func _reject(ctx: Dictionary, severity: String, code: String, message: String) -> void:
	if ctx.has("_sink") and ctx["_sink"] is Array:
		ctx["_sink"].append(CFIssue.make(severity, code, message, ctx))


# ---------------------------------------------------------------- 单值类型化

## 单值类型化（UI 单元格编辑、导入、加载共用同一套规则）。
## 返回 { ok, value, issue }：ok=false 时 value 是默认占位值、issue 是问题对象。
static func convert_value(schema: CFSchema, field: Dictionary, raw: Variant, ctx: Dictionary) -> Dictionary:
	var info: Dictionary = field["info"]
	var nullable := bool(info.get("nullable", false))
	var kind := str(field["kind"])

	if raw == null:
		if nullable:
			return {"ok": true, "value": null, "issue": null}
		return _fail(schema, field, ctx, "E_FIELD_NULL", "字段值为 null（类型 %s 不可空）" % str(field["type"]))

	if raw is String:
		var stripped := str(raw).strip_edges()
		if stripped == "":
			if nullable:
				return {"ok": true, "value": null, "issue": null}
			if bool(field["required"]):
				return _fail(schema, field, ctx, "E_FIELD_REQUIRED", "必填字段为空")
			return {"ok": true, "value": default_of(schema, field), "issue": null}

	match kind:
		"scalar":
			return _convert_scalar(schema, field, raw, ctx, str(info["type"]))
		"enum":
			return _convert_enum(schema, field, raw, ctx, str(info["type"]))
		"list":
			return _convert_list(schema, field, raw, ctx)
		"map":
			return _convert_map(schema, field, raw, ctx)
		"bean":
			return _convert_bean(schema, field, raw, ctx)
	return _fail(schema, field, ctx, "E_TYPE", "未知字段类型 %s" % str(field["type"]))


static func _convert_scalar(schema: CFSchema, field: Dictionary, raw: Variant, ctx: Dictionary, scalar: String) -> Dictionary:
	match scalar:
		"int":
			if raw is int:
				return _ok(raw)
			if raw is bool:
				return _ok(1 if raw else 0)
			if raw is float:
				if float(raw) == float(int(raw)):
					return _ok(int(raw))
				return _fail(schema, field, ctx, "E_TYPE_INT", "需要整数，实际为 %s" % str(raw))
			var s := str(raw).strip_edges()
			if s.is_valid_int():
				return _ok(int(s))
			if s.is_valid_float() and float(s) == float(int(float(s))):
				return _ok(int(float(s)))
			return _fail(schema, field, ctx, "E_TYPE_INT", "需要整数，实际为 %s" % s)
		"float":
			if raw is float or raw is int:
				return _ok(float(raw))
			if raw is bool:
				return _ok(1.0 if raw else 0.0)
			var s2 := str(raw).strip_edges()
			if s2.is_valid_float():
				return _ok(float(s2))
			return _fail(schema, field, ctx, "E_TYPE_FLOAT", "需要浮点数，实际为 %s" % s2)
		"bool":
			if raw is bool:
				return _ok(raw)
			if raw is int or raw is float:
				return _ok(float(raw) != 0.0)
			var s3 := str(raw).strip_edges().to_lower()
			if s3 == "true" or s3 == "1" or s3 == "yes" or s3 == "y" or s3 == "是" or s3 == "真":
				return _ok(true)
			if s3 == "false" or s3 == "0" or s3 == "no" or s3 == "n" or s3 == "否" or s3 == "假":
				return _ok(false)
			return _fail(schema, field, ctx, "E_TYPE_BOOL", "需要 true/false，实际为 %s" % s3)
		"string":
			if raw is String:
				return _ok(str(raw))
			if raw is bool:
				return _ok("true" if raw else "false")
			if raw is int or raw is float:
				return _ok(_number_to_text(raw))
			return _fail(schema, field, ctx, "E_TYPE_STRING", "需要字符串，实际为 %s" % _json_kind(raw))
	return _fail(schema, field, ctx, "E_TYPE", "未知标量 %s" % scalar)


static func _convert_enum(schema: CFSchema, field: Dictionary, raw: Variant, ctx: Dictionary, enum_name: String) -> Dictionary:
	if not schema.enums.has(enum_name):
		return _fail(schema, field, ctx, "E_ENUM_UNKNOWN", "引用了未定义的枚举 %s" % enum_name)
	var edef: Dictionary = schema.enums[enum_name]
	var values: Dictionary = edef["values"]
	var aliases: Dictionary = edef.get("aliases", {})
	var candidates := _enum_options(edef)

	if raw is int:
		if values.values().has(raw):
			return _ok(raw)
		return _fail(schema, field, ctx, "E_ENUM_VALUE", "枚举 %s 没有取值 %d（可选：%s）" % [enum_name, raw, candidates])
	if raw is float:
		if float(raw) == float(int(raw)) and values.values().has(int(raw)):
			return _ok(int(raw))
		return _fail(schema, field, ctx, "E_ENUM_VALUE", "枚举 %s 没有取值 %s（可选：%s）" % [enum_name, _number_to_text(raw), candidates])
	if raw is bool:
		return _fail(schema, field, ctx, "E_ENUM_VALUE", "枚举 %s 不接受布尔值（可选：%s）" % [enum_name, candidates])

	var s := str(raw).strip_edges()
	if values.has(s):
		return _ok(int(values[s]))
	if aliases.has(s):
		return _ok(int(aliases[s]))
	if s.is_valid_int() and values.values().has(int(s)):
		return _ok(int(s))
	return _fail(schema, field, ctx, "E_ENUM_VALUE", "枚举 %s 没有取值 %s（可选：%s）" % [enum_name, s, candidates])


static func _convert_list(schema: CFSchema, field: Dictionary, raw: Variant, ctx: Dictionary) -> Dictionary:
	var elems: Array = []
	if raw is Array:
		elems = raw
	elif raw is Dictionary:
		return _fail(schema, field, ctx, "E_TYPE_LIST", "需要数组，实际为对象")
	else:
		var sep := str(field["sep"])
		for piece in str(raw).split(sep):
			elems.append(piece)
	var elem_f := elem_field(field, "elem")
	var out: Array = []
	for i in range(elems.size()):
		var elem: Variant = elems[i]
		if elem is String and str(elem).strip_edges() == "":
			continue  # 容忍 a||b / 末尾多余分隔符
		var elem_ctx := {"table": str(ctx.get("table", "")), "row": ctx.get("row", 0), "field": "%s[%d]" % [str(field["name"]), i], "file": str(ctx.get("file", ""))}
		var conv := convert_value(schema, elem_f, elem, elem_ctx)
		if conv["issue"] != null:
			return _fail(schema, field, ctx, "E_LIST_ELEM", "元素 %d 非法：%s" % [i, str(conv["issue"]["message"])])
		out.append(conv["value"])
	if bool(field["info"].get("is_set", false)):
		var seen: Dictionary = {}
		for v in out:
			if seen.has(v):
				return _fail(schema, field, ctx, "E_SET_DUPLICATE", "set 容器出现重复元素 %s" % str(v))
			seen[v] = true
	return _ok(out)


static func _convert_map(schema: CFSchema, field: Dictionary, raw: Variant, ctx: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	if raw is Dictionary:
		var key_field := elem_field(field, "key")
		var val_field := elem_field(field, "value")
		for k in raw.keys():
			var kconv := convert_value(schema, key_field, k, ctx)
			if kconv["issue"] != null:
				return _fail(schema, field, ctx, "E_MAP_KEY", "键 %s 非法：%s" % [str(k), str(kconv["issue"]["message"])])
			var vconv := convert_value(schema, val_field, raw[k], ctx)
			if vconv["issue"] != null:
				return _fail(schema, field, ctx, "E_MAP_VALUE", "键 %s 的值非法：%s" % [str(k), str(vconv["issue"]["message"])])
			out[kconv["value"]] = vconv["value"]
		return _ok(out)
	var text := str(raw).strip_edges()
	if text == "":
		return _ok({})
	var sep := str(field["sep"])
	var key_field2 := elem_field(field, "key")
	var val_field2 := elem_field(field, "value")
	for pair in text.split(sep):
		var pt := str(pair).strip_edges()
		if pt == "":
			continue
		var idx := pt.find(":")
		if idx < 0:
			return _fail(schema, field, ctx, "E_MAP_PAIR", "键值对 %s 缺少冒号（应形如 key:value）" % pt)
		var kconv2 := convert_value(schema, key_field2, pt.substr(0, idx).strip_edges(), ctx)
		if kconv2["issue"] != null:
			return _fail(schema, field, ctx, "E_MAP_KEY", "键 %s 非法：%s" % [pt.substr(0, idx), str(kconv2["issue"]["message"])])
		var vconv2 := convert_value(schema, val_field2, pt.substr(idx + 1).strip_edges(), ctx)
		if vconv2["issue"] != null:
			return _fail(schema, field, ctx, "E_MAP_VALUE", "键 %s 的值非法：%s" % [pt.substr(0, idx), str(vconv2["issue"]["message"])])
		out[kconv2["value"]] = vconv2["value"]
	return _ok(out)


static func _convert_bean(schema: CFSchema, field: Dictionary, raw: Variant, ctx: Dictionary) -> Dictionary:
	if not (raw is Dictionary):
		return _fail(schema, field, ctx, "E_TYPE_BEAN", "需要对象，实际为 %s" % _json_kind(raw))
	var conv := convert_record(schema, str(field["info"]["type"]), raw, ctx)
	# 子结构里的第一条 error 折成一条，挂在当前字段上（保证问题能定位到外层字段）
	for it in conv["issues"]:
		if str(it.get("severity", "")) == CFIssue.ERROR:
			return _fail(schema, field, ctx, "E_BEAN", str(it.get("message", "")))
	return _ok(conv["record"])


## 给容器元素/键值造一个「伪字段」，复用同一套单值转换。
static func elem_field(field: Dictionary, slot: String) -> Dictionary:
	var info: Dictionary = field["info"].get(slot, {})
	var required := true
	var k := str(info.get("kind", ""))
	if k == "scalar" and str(info.get("type", "")) == TYPE_STRING:
		required = false
	elif k == "list" or k == "map" or k == "bean":
		required = false
	return {
		"name": str(field["name"]),
		"type": str(info.get("raw", "")),
		"kind": k,
		"info": info,
		"comment": "",
		"required": required,
		"sep": "|",
		"ref": "",
		"min": null,
		"max": null,
		"len_min": 0,
		"len_max": 0,
		"pattern": "",
		"path": "",
		"alias": "",
	}


# ---------------------------------------------------------------- 默认值 / 工具

## 字段默认值（类型默认值 + 枚举取首个取值），用于新增行与坏值占位。
static func default_of(schema: CFSchema, field: Dictionary) -> Variant:
	return CFTypeSystem.default_value(field["info"], schema.enums)


## 枚举可选值说明文本（报错时提示「可选：Common=1, Rare=2」）。
static func _enum_options(edef: Dictionary) -> String:
	var parts: Array = []
	var order: Array = edef.get("order", [])
	var values: Dictionary = edef["values"]
	for vname in order:
		parts.append("%s=%d" % [str(vname), int(values[vname])])
	if parts.is_empty():
		return "（无取值）"
	return ", ".join(parts)


## 转换成功的统一返回形状。
static func _ok(value: Variant) -> Dictionary:
	return {"ok": true, "value": value, "issue": null}


## 转换失败：value 用类型默认值占位（保证 UI 能显示），issue 供上层收集。
static func _fail(schema: CFSchema, field: Dictionary, ctx: Dictionary, code: String, message: String) -> Dictionary:
	var issue := CFIssue.make(CFIssue.ERROR, code, "%s（字段 %s）" % [message, str(field["name"])], {
		"table": str(ctx.get("table", "")),
		"row": ctx.get("row", 0),
		"field": str(ctx.get("field", field["name"])),
		"file": str(ctx.get("file", "")),
	})
	return {"ok": false, "value": default_of(schema, field), "issue": issue}


## 报错时用的中文类型描述（「需要对象，实际为字符串」里的后半句）。
static func _json_kind(value: Variant) -> String:
	if value is Dictionary:
		return "对象"
	if value is Array:
		return "数组"
	if value is bool:
		return "布尔"
	if value is int or value is float:
		return "数字"
	if value is String:
		return "字符串"
	return "null"


## 数字转文本（委托 CFTypeSystem.number_text）。
static func _number_to_text(value: Variant) -> String:
	return CFTypeSystem.number_text(value)


## 拼 res:// 路径，容忍目录结尾带不带斜杠。
## 全工具链只此一份（pipeline / CLI 都委托到这里），避免各写一份还写得不一样。
static func join_path(dir: String, file_name: String) -> String:
	var d := str(dir).strip_edges()
	if d == "":
		return file_name
	if d.ends_with("/"):
		return d + file_name
	return d + "/" + file_name


## 整表加载失败（文件缺失/不是合法 JSON）时的空结果，仍带上那条 error。
static func _empty_result(path: String, issue: Dictionary) -> Dictionary:
	return {"name": "", "records": [], "lines": [], "file": path, "issues": [issue]}


# ---------------------------------------------------------------- 导出

## 记录 → CSV 行（含 ##var / ##type / ##comment 表头），供保存回源文件与导出。
static func records_to_csv_rows(schema: CFSchema, table: Dictionary, records: Array) -> Array:
	var fields: Array = table["bean"]["fields"]
	var var_row: Array = ["##var"]
	var type_row: Array = ["##type"]
	var comment_row: Array = ["##comment"]
	var has_comment := false
	for f in fields:
		var cell := str(f["name"])
		# 只写 #ref= 这类安全字符的注释；不写 #sep=：
		# sep 由 schema 定义，而 "|" 出现在表头会被 Godot 的 csv_translation 导入器
		# 当成列名的一部分去创建文件名（Windows 上非法），导入会一直失败刷错误。
		if str(f["ref"]) != "":
			cell += "#ref=%s" % str(f["ref"])
		var_row.append(cell)
		type_row.append(str(f["type"]))
		var c := str(f["comment"])
		if c != "":
			has_comment = true
		comment_row.append(c)
	var rows: Array = [var_row, type_row]
	if has_comment:
		rows.append(comment_row)
	for rec in records:
		var row: Array = [""]
		for f in fields:
			row.append(_cell_text(schema, rec.get(str(f["name"])), f))
		rows.append(row)
	return rows


## 单值 → CSV 单元格文本。枚举写取值名（比数字好读，也能原样解析回来）；
## list/map 用分隔符拼；bean 只能写成 JSON 文本。
static func _cell_text(schema: CFSchema, value: Variant, field: Dictionary) -> String:
	if value == null:
		return ""
	var kind := str(field["kind"])
	if kind == "enum":
		var enum_name := schema.enum_name_of(str(field["info"].get("type", "")), value)
		if enum_name != "":
			return enum_name
		return _scalar_text(value)
	if kind == "list":
		var parts: Array = []
		if value is Array:
			for v in value:
				parts.append(_scalar_text(v))
		return str(field["sep"]).join(parts)
	if kind == "map":
		var pairs: Array = []
		if value is Dictionary:
			for k in value.keys():
				pairs.append("%s:%s" % [_scalar_text(k), _scalar_text(value[k])])
		return str(field["sep"]).join(pairs)
	if kind == "bean":
		return JSON.stringify(value, "", false)
	return _scalar_text(value)


## 单值 → 展示文本（委托 CFTypeSystem，避免每个模块各写一份格式化）。
static func _scalar_text(value: Variant) -> String:
	return CFTypeSystem.scalar_text(value)


## 记录 → 可 JSON 序列化的纯数据（已是纯 Dictionary，这里只做字段顺序整理与 $type 处理）。
static func records_to_plain(schema: CFSchema, table: Dictionary, records: Array) -> Array:
	var out: Array = []
	var fields: Array = table["bean"]["fields"]
	for rec in records:
		var clean: Dictionary = {}
		for f in fields:
			var fname := str(f["name"])
			if rec.has(fname):
				clean[fname] = rec[fname]
		if rec.has("$type"):
			clean["$type"] = rec["$type"]
		out.append(clean)
	return out
