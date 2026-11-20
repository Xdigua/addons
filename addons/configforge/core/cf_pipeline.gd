@tool
class_name CFPipeline
extends RefCounted

## 配置工坊 · DPP 管线编排
##
## 对齐 Luban 的 Data Process Pipeline 分段思路，每段职责单一、可单独调用：
##   schema 加载  → 数据加载/类型化  → 语义校验  → 代码生成  → 数据导出
##
## 编辑器面板（ui/dock_main.gd）与 headless CLI（cli/cfg_cli.gd）共用本类，
## 保证「面板里跑通」与「命令行跑通」是同一条管线、同一套判定。
##
## 目录约定：插件在宿主工程里**只落一个根目录**，顶层结构只多一个 configforge/。
##   configforge/schema.json   结构定义（源）
##   configforge/data/*.json   数据源（源，手写或导入）
##   configforge/out/          生成物：schema.gd、loader.gd、各表 json
## 源和产物分两个子目录，且名字大小写不同也不会撞（Windows 不区分大小写）。
## 想换位置可以整体挪（configure() 里改四个路径，或 CLI 的 --schema/--data/--code-out/--data-out）。
const ROOT_DIR := "res://configforge"
const SOURCE_DIR := ROOT_DIR + "/data"
const OUTPUT_DIR := ROOT_DIR + "/out"

var schema_path := ROOT_DIR + "/schema.json"
var data_dir := SOURCE_DIR
var code_out_dir := OUTPUT_DIR
var data_out_dir := OUTPUT_DIR
var group := ""

## 数据是否合并成一个 JSON（默认不合并，每张表一个文件）。
##   false → 每张表一个 <data_out>/<表名小写>.json（默认）
##   true  → <data_out>/config.json：{ "tbitem": [...], "tbmonster": [...] }
## 两种产物 loader 都能读（合并文件优先，缺了再回退到单表文件）。
var merge_data := false
var data_file_name := "config.json"

var schema: CFSchema = null
var tables: Dictionary = {}
var issues: Array = []
var logs: Array = []
var written_files: Array = []


func _init() -> void:
	schema = CFSchema.new()


## 批量设置目录。opts 支持 schema_path / data_dir / code_out_dir / data_out_dir / group。
func configure(opts: Dictionary) -> void:
	if opts.has("schema_path"):
		schema_path = str(opts["schema_path"])
	if opts.has("data_dir"):
		data_dir = str(opts["data_dir"])
	if opts.has("code_out_dir"):
		code_out_dir = str(opts["code_out_dir"])
	if opts.has("data_out_dir"):
		data_out_dir = str(opts["data_out_dir"])
	if opts.has("group"):
		group = str(opts["group"])
	if opts.has("merge"):
		merge_data = bool(opts["merge"])
	if opts.has("data_file"):
		data_file_name = str(opts["data_file"])


## 目录配置快照（写进 CLI 结果，便于 Agent 判断环境）。
func dirs() -> Dictionary:
	return {
		"schema": schema_path,
		"data_src": data_dir,
		"code_out": code_out_dir,
		"data_out": data_out_dir,
		"group": group,
	}


# ---------------------------------------------------------------- 1. schema

## 读取并解析 structure 文件。失败时 schema.issues 里带原因。
func load_schema() -> bool:
	schema = CFSchema.new()
	var ok := schema.load_from_file(schema_path)
	if not ok:
		for it in schema.issues:
			logs.append(CFIssue.format(it))
	return ok


# ---------------------------------------------------------------- 2. 数据

## 加载全部表数据（类型化记录 + 每条记录的问题）。返回是否无 error。
func load_data() -> bool:
	tables = {}
	if schema == null or schema.tables.is_empty():
		return true
	var result := CFDataLoader.load_all(schema, data_dir)
	tables = result["tables"]
	var ok := true
	for t in schema.tables:
		var name := str(t["name"])
		var loaded: Dictionary = tables.get(name, {})
		var count := 0
		if loaded.has("records"):
			count = loaded["records"].size()
		ok = ok and CFIssue.count_errors(loaded.get("issues", [])) == 0
		logs.append("数据加载：%s ← %s（%d 条）" % [name, str(t["input"]), count])
	return ok


# ---------------------------------------------------------------- 3. 校验

## 全量校验（加载期问题 + 语义问题），结果写回 issues 并返回。
func validate() -> Array:
	var all: Array = []
	if schema != null:
		for t in schema.tables:
			var loaded: Dictionary = tables.get(str(t["name"]), {})
			all.append_array(loaded.get("issues", []))
		all.append_array(CFValidator.validate(schema, tables))
	issues = CFIssue.sorted(CFIssue.dedupe(all))
	return issues


# ---------------------------------------------------------------- 4. 生成

## 生成代码与数据（不校验，调用方保证已经通过校验）。
## 返回 { ok, files: Array[String], issues: Array }。
func generate(opts: Dictionary = {}) -> Dictionary:
	var group_filter := str(opts.get("group", group))
	var merge := bool(opts.get("merge", merge_data))
	var out_tables: Array = schema.tables_for_group(group_filter)
	var code_dir := str(opts.get("code_out_dir", code_out_dir))
	var out_data_dir := str(opts.get("data_out_dir", data_out_dir))
	var files: Array = []
	var write_issues: Array = []

	_ensure_dir(code_dir)
	var gen := CFCodeGen.generate(schema, out_tables, out_data_dir, code_dir, data_file_name)
	_write_text(_join(code_dir, "schema.gd"), str(gen["schema_gd"]), files, write_issues)
	_write_text(_join(code_dir, "loader.gd"), str(gen["loader_gd"]), files, write_issues)

	_ensure_dir(out_data_dir)
	if merge:
		# 合并模式：所有表进一个 JSON，键是「表名小写」的文件名主干
		var merged: Dictionary = {}
		for table in out_tables:
			var name := str(table["name"])
			var loaded: Dictionary = tables.get(name, {})
			var records: Array = loaded.get("records", [])
			merged[str(table["file_stem"])] = CFDataLoader.records_to_plain(schema, table, records)
		var merged_text := JSON.stringify(merged, "\t", false) + "\n"
		_write_text(_join(out_data_dir, data_file_name), merged_text, files, write_issues)
	else:
		for table in out_tables:
			var name2 := str(table["name"])
			var loaded2: Dictionary = tables.get(name2, {})
			var records2: Array = loaded2.get("records", [])
			var plain := CFDataLoader.records_to_plain(schema, table, records2)
			var text := JSON.stringify(plain, "\t", false) + "\n"
			_write_text(_join(out_data_dir, str(table["file_stem"]) + ".json"), text, files, write_issues)
		# 删掉上次的合并产物：loader 是「config.json 优先」，留着旧文件会盖住刚生成的分表数据
		var stale_merged := _join(out_data_dir, data_file_name)
		if FileAccess.file_exists(stale_merged):
			DirAccess.remove_absolute(stale_merged)

	written_files = files
	return {"ok": write_issues.is_empty(), "files": files, "issues": write_issues}


## 代码文本预览：只生成文本、不落盘（CLI 的 --dry-run 用它验证生成器并汇报体积）。
func preview_code(opts: Dictionary = {}) -> Dictionary:
	var group_filter := str(opts.get("group", group))
	var code_dir := str(opts.get("code_out_dir", code_out_dir))
	var out_data_dir := str(opts.get("data_out_dir", data_out_dir))
	return CFCodeGen.generate(schema, schema.tables_for_group(group_filter), out_data_dir, code_dir, data_file_name)


# ---------------------------------------------------------------- 全流程

## 跑完整管线。opts 支持 generate(bool，默认 true)、group。
## 返回 { ok, stage, issues, logs, files, stats, dirs }。
func run(opts: Dictionary = {}) -> Dictionary:
	logs = []
	written_files = []
	var do_generate := true
	if opts.has("generate"):
		do_generate = bool(opts["generate"])
	var run_group := str(opts.get("group", group))
	logs.append("== 配置工坊 · DPP 管线 ==")
	logs.append("结构文件：%s" % schema_path)

	# 1) schema
	if not load_schema():
		logs.append("结构解析失败：%d 个错误" % schema.error_count())
		issues = CFIssue.sorted(CFIssue.dedupe(schema.issues))
		return _result(false, "schema", [], {})

	logs.append("结构解析通过：%d 个枚举 / %d 个结构 / %d 张表"
		% [schema.enums.size(), schema.beans.size(), schema.tables.size()])

	# 2) 数据
	if not load_data():
		validate()
		logs.append("数据加载存在错误：%d 个" % CFIssue.count_errors(issues))
		return _result(false, "data", [], {})

	# 3) 校验
	validate()
	var errors := CFIssue.count_errors(issues)
	var warnings := CFIssue.count_warnings(issues)
	logs.append("校验：%d 个错误 / %d 个警告" % [errors, warnings])
	if errors > 0:
		return _result(false, "validate", [], _stats())
	for it in issues:
		if str(it.get("severity", "")) == CFIssue.WARNING:
			logs.append(CFIssue.format(it))

	# 4) 生成
	if not do_generate:
		logs.append("已跳过生成（generate=false）")
		return _result(true, "validate", [], _stats())

	var gen_opts: Dictionary = {"group": run_group}
	if opts.has("merge"):
		gen_opts["merge"] = opts["merge"]
	var gen := generate(gen_opts)
	issues.append_array(gen["issues"])
	for path in gen["files"]:
		logs.append("写入：%s" % str(path))
	if not bool(gen["ok"]):
		logs.append("生成写入失败")
		return _result(false, "generate", [], _stats())

	logs.append("生成完成：%d 个文件" % gen["files"].size())
	return _result(true, "done", gen["files"], _stats())


func _result(ok: bool, stage: String, files: Array, stats: Dictionary) -> Dictionary:
	return {
		"ok": ok,
		"stage": stage,
		"issues": issues.duplicate(),
		"logs": logs.duplicate(),
		"files": files.duplicate(),
		"stats": stats,
		"dirs": dirs(),
	}


## 统计快照：枚举/结构/表数量 + 每表记录数（run() 的返回值里用）。
func _stats() -> Dictionary:
	var counts: Dictionary = {}
	var total := 0
	var enum_count := 0
	var bean_count := 0
	var table_count := 0
	if schema != null:
		enum_count = schema.enums.size()
		bean_count = schema.beans.size()
		table_count = schema.tables.size()
		for t in schema.tables:
			var name := str(t["name"])
			var loaded: Dictionary = tables.get(name, {})
			var n := 0
			if loaded.has("records"):
				n = loaded["records"].size()
			counts[name] = n
			total += n
	return {
		"enums": enum_count,
		"beans": bean_count,
		"tables": table_count,
		"records": total,
		"per_table": counts,
	}


# ---------------------------------------------------------------- 单表操作

## 把内存里的表数据写回源文件（CSV 重建表头，JSON 数组）。
func save_table(table_name: String) -> Dictionary:
	var table := schema.table_by_name(table_name)
	if table.is_empty():
		return {"ok": false, "error": "未知表：%s" % table_name, "path": ""}
	var loaded: Dictionary = tables.get(table_name, {})
	var records: Array = loaded.get("records", [])
	var path := _join(data_dir, str(table["file_name"]))
	_ensure_dir(path.get_base_dir())
	if str(table["source"]) == "json":
		var plain := CFDataLoader.records_to_plain(schema, table, records)
		var text := JSON.stringify(plain, "\t", false) + "\n"
		var res := _write_text(path, text, [], [])
		if bool(res["ok"]):
			loaded["file"] = path
			tables[table_name] = loaded
		return {"ok": bool(res["ok"]), "error": str(res["error"]), "path": path, "count": records.size()}
	var rows := CFDataLoader.records_to_csv_rows(schema, table, records)
	var sep := CFCsv.sep_for_file(str(table["file_name"]))
	var wres := CFCsv.write_file(path, rows, sep)
	if bool(wres["ok"]):
		loaded["file"] = path
		tables[table_name] = loaded
	return {"ok": bool(wres["ok"]), "error": str(wres["error"]), "path": path, "count": records.size()}


## 导入外部数据到内存中的表。
##   mode = "replace"（默认）：整体替换；索引重复仍然拒绝（否则表当场就是坏的）
##   mode = "append"          ：追加到现有数据末尾，index 已存在的记录**跳过**（计入 skipped）
## fmt: "csv" | "json"（留空按源文件后缀判）。
## source_name: 被导入文件的名字/路径——CSV 的分隔符按它推断，而不是按表原来那个数据源。
func import_table(table_name: String, text: String, fmt: String = "", source_name: String = "", mode: String = "replace") -> Dictionary:
	var table := schema.table_by_name(table_name)
	if table.is_empty():
		return {"ok": false, "issues": [], "error": "未知表：%s" % table_name}
	var use_fmt := fmt
	if use_fmt == "":
		use_fmt = "json" if str(table["source"]) == "json" else "csv"
	# 去掉 BOM：Excel/记事本导出的文件常带，JSON.parse_string 会被它噎住
	var clean := CFCsv.strip_bom(text)
	var loaded: Dictionary
	if use_fmt == "json":
		var parsed: Variant = JSON.parse_string(clean)
		if parsed == null:
			return {"ok": false, "issues": [CFIssue.make(CFIssue.ERROR, "E_IMPORT_JSON", "导入内容不是合法 JSON")], "error": "JSON 解析失败"}
		loaded = CFDataLoader.parse_json_records(schema, table, parsed, "<import>")
	else:
		var sep_name := source_name if source_name != "" else str(table["file_name"])
		loaded = CFDataLoader.parse_csv_text(schema, table, clean, "<import>", CFCsv.sep_for_file(sep_name))

	# 「缺列」算可容忍：别人的文件少几列时，单元格按类型默认值填，
	# 只记 warning 不拒绝（不然任何不同结构的 JSON/CSV 都导不进来）。
	var blocking := 0
	for it in loaded["issues"]:
		if str(it.get("severity", "")) != CFIssue.ERROR:
			continue
		if str(it.get("code", "")) == "E_FIELD_MISSING_COLUMN":
			continue
		blocking += 1
	if blocking > 0:
		return {"ok": false, "issues": loaded["issues"], "error": "导入内容存在 %d 个错误，已拒绝" % blocking}

	var incoming: Array = loaded["records"]
	var idx := schema.index_field(table)
	var idx_name := ""
	if not idx.is_empty():
		idx_name = str(idx["name"])

	if mode != "append":
		# 替换：整表换掉。索引重复必须拒绝，否则导入完这张表当场就是坏的
		if idx_name != "":
			var seen: Dictionary = {}
			for i in range(incoming.size()):
				var rec: Dictionary = incoming[i]
				var v: Variant = rec.get(idx_name, null)
				if v == null:
					continue
				if seen.has(v):
					loaded["issues"].append(CFIssue.make(CFIssue.ERROR, "E_IMPORT_DUPLICATE",
						"导入数据里 %s=%s 重复（第 %d 条与第 %d 条）" % [idx_name, str(v), int(seen[v]), i + 1],
						{"table": table_name, "row": i + 1, "field": idx_name}))
					break
				seen[v] = i + 1
			if CFIssue.count_errors(loaded["issues"]) > 0:
				return {"ok": false, "issues": loaded["issues"], "error": "导入数据存在重复索引，已拒绝替换"}
		loaded["file"] = _join(data_dir, str(table["file_name"]))
		tables[table_name] = loaded
		return {"ok": true, "issues": loaded["issues"], "error": "", "count": incoming.size(), "skipped": 0}

	# 追加：index 已存在的记录跳过（不报错，只在结果里计数）
	var loaded_now: Dictionary = tables.get(table_name, {})
	if not loaded_now.has("records"):
		loaded_now["records"] = []
		loaded_now["lines"] = []
		loaded_now["issues"] = []
		loaded_now["file"] = ""
	var records: Array = loaded_now["records"]
	var existing: Dictionary = {}
	if idx_name != "":
		for rec in records:
			if rec is Dictionary and rec.has(idx_name):
				existing[rec[idx_name]] = true
	var appended := 0
	var skipped := 0
	for rec in incoming:
		if idx_name != "":
			var v: Variant = rec.get(idx_name, null)
			if v != null and existing.has(v):
				skipped += 1
				continue
			if v != null:
				existing[v] = true
		records.append(rec)
		appended += 1
	loaded_now["records"] = records
	tables[table_name] = loaded_now
	return {"ok": true, "issues": loaded["issues"], "error": "", "count": appended, "skipped": skipped}


## 导出当前表到指定文件（按 fmt：csv / json），不改源文件。
func export_table(table_name: String, path: String, fmt: String = "csv") -> Dictionary:
	var table := schema.table_by_name(table_name)
	if table.is_empty():
		return {"ok": false, "error": "未知表：%s" % table_name}
	var loaded: Dictionary = tables.get(table_name, {})
	var records: Array = loaded.get("records", [])
	if fmt == "json":
		var plain := CFDataLoader.records_to_plain(schema, table, records)
		return _write_text(path, JSON.stringify(plain, "\t", false) + "\n", [], [])
	var rows := CFDataLoader.records_to_csv_rows(schema, table, records)
	var sep := "," if not path.to_lower().ends_with(".tsv") else "\t"
	return CFCsv.write_file(path, rows, sep)


## 新建一条记录（索引字段自动取当前最大值 +1，其余为类型默认值）。
func new_record(table_name: String) -> Dictionary:
	var table := schema.table_by_name(table_name)
	if table.is_empty():
		return {}
	var rec: Dictionary = {}
	for f in table["bean"]["fields"]:
		rec[str(f["name"])] = CFDataLoader.default_of(schema, f)
	var index := str(table.get("index", ""))
	if index != "":
		rec[index] = _next_index(table, index)
	return rec


## 哪些地方引用了目标表里的这个索引值（删除保护用）。
## 返回 [{ table, row, field }]。
func references_to(target_table: String, value: Variant) -> Array:
	var out: Array = []
	if value == null:
		return out
	for t in schema.tables:
		var tname := str(t["name"])
		var loaded: Dictionary = tables.get(tname, {})
		var records: Array = loaded.get("records", [])
		for f in t["bean"]["fields"]:
			if str(f["ref"]) != target_table:
				continue
			var fname := str(f["name"])
			for i in range(records.size()):
				if not (records[i] is Dictionary):
					continue
				if _value_refers(records[i].get(fname, null), value):
					out.append({"table": tname, "row": i + 1, "field": fname})
	return out


## 索引值变更后，同步所有引用它的表的标量/列表元素（map 值不自动改，只记日志）。
func cascade_index(table_name: String, old_value: Variant, new_value: Variant) -> Array:
	var changed: Array = []
	for t in schema.tables:
		var tname := str(t["name"])
		var loaded: Dictionary = tables.get(tname, {})
		var records: Array = loaded.get("records", [])
		for f in t["bean"]["fields"]:
			if str(f["ref"]) != table_name:
				continue
			var fname := str(f["name"])
			var kind := str(f["kind"])
			for i in range(records.size()):
				if not (records[i] is Dictionary):
					continue
				var rec: Dictionary = records[i]
				if not rec.has(fname):
					continue
				var v: Variant = rec[fname]
				if kind == "list" and v is Array:
					var hit := false
					for j in range(v.size()):
						if v[j] == old_value:
							v[j] = new_value
							hit = true
					if hit:
						rec[fname] = v
						changed.append({"table": tname, "row": i + 1, "field": fname})
				elif v == old_value:
					rec[fname] = new_value
					changed.append({"table": tname, "row": i + 1, "field": fname})
	return changed


# ---------------------------------------------------------------- 内部工具

## 统计快照：枚举/结构/表数量 + 每表记录数（UI 状态栏与 CLI 输出共用）。
func stats() -> Dictionary:
	return _stats()


## 给「新增行」算一个不冲突的索引值：
##   - 整数索引：取现有最大值 +1，并跳过已被占用的值（防止手动改过 id 后撞号）；
##   - 其它类型：用 r1、r2 … 递增，同样跳过已占用的。
func _next_index(table: Dictionary, index: String) -> Variant:
	var field := schema.bean_field(str(table["bean_name"]), index)
	var info: Dictionary = field.get("info", {})
	var is_int := str(info.get("kind", "")) == "scalar" and str(info.get("type", "")) == "int"
	var loaded: Dictionary = tables.get(str(table["name"]), {})
	var records: Array = loaded.get("records", [])
	# 先把现有索引值都收进来，用于「撞号就加一」
	var used: Dictionary = {}
	if is_int:
		var max_v := 0
		for rec in records:
			if not (rec is Dictionary) or not rec.has(index):
				continue
			var v: Variant = rec[index]
			var iv := 0
			var has_iv := false
			if v is int:
				iv = v
				has_iv = true
			elif v is float:
				iv = int(v)
				has_iv = true
			if not has_iv:
				continue
			used[iv] = true
			if iv > max_v:
				max_v = iv
		var next := max_v + 1
		while used.has(next):
			next += 1
		return next

	for rec in records:
		if rec is Dictionary and rec.has(index):
			used[str(rec[index])] = true
	var n := records.size() + 1
	while used.has("r%d" % n):
		n += 1
	return "r%d" % n


## 判断某个记录值是否引用到 target：标量直接比，list 逐个比，map 比值。
## （删除保护与 id 级联共用，所以三种形态都要覆盖。）
func _value_refers(value: Variant, target: Variant) -> bool:
	if value is Array:
		for v in value:
			if v == target:
				return true
		return false
	if value is Dictionary:
		for k in value.keys():
			if value[k] == target:
				return true
		return false
	if value == null:
		return false
	return value == target


## 目录不存在就递归创建（res:// 与 user:// 都适用）。
func _ensure_dir(path: String) -> void:
	if path == "" or DirAccess.dir_exists_absolute(path):
		return
	DirAccess.make_dir_recursive_absolute(path)


## 拼路径（委托 CFDataLoader.join_path，全工具链一份实现）。
func _join(dir: String, file_name: String) -> String:
	return CFDataLoader.join_path(dir, file_name)


## 写文本文件并记录「写了哪些文件 / 写失败的原因」，返回 { ok, error }。
func _write_text(path: String, text: String, files: Array, errs: Array) -> Dictionary:
	_ensure_dir(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		var err := "无法写入文件：%s（err=%d）" % [path, FileAccess.get_open_error()]
		errs.append(CFIssue.make(CFIssue.ERROR, "E_WRITE", err, {"file": path}))
		return {"ok": false, "error": err}
	f.store_string(text)
	f.close()
	files.append(path)
	return {"ok": true, "error": ""}
