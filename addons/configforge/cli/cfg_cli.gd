extends SceneTree

## 配置工坊 · Agent CLI（headless）
##
## 对应 Luban 5.0 的 AI Native 思路：把「查表、看结构、校验、生成」做成机器可读的稳定接口，
## 让 AI Agent / CI 能直接调用，不需要人盯着编辑器面板。
##
## 用法（命令放在 `--` 之后，`--` 之前是 Godot 自己的参数）：
##   godot --headless --path . --script res://addons/configforge/cli/cfg_cli.gd -- capabilities
##   godot --headless --path . --script res://addons/configforge/cli/cfg_cli.gd -- list-tables
##   godot --headless --path . --script res://addons/configforge/cli/cfg_cli.gd -- schema
##   godot --headless --path . --script res://addons/configforge/cli/cfg_cli.gd -- describe --table=TbItem
##   godot --headless --path . --script res://addons/configforge/cli/cfg_cli.gd -- validate
##   godot --headless --path . --script res://addons/configforge/cli/cfg_cli.gd -- generate [--dry-run]
##
## 公共参数：
##   --schema=res://configforge/schema.json  --data=res://configforge/Data
##   --code-out=res://configforge/cfg       --data-out=res://configforge/data
##   --group=c                          按表 group 过滤
##   --errorFormat=json|text            报错格式（默认 json，与 Luban 的 --errorFormat 对齐）
##   --pretty                           JSON 缩进输出
##
## 退出码（与 Luban.Agent 一致）：0 成功 / 1 数据或校验错误 / 2 结构或配置错误
##                              3 用法错误 / 4 内部错误

const TOOL := "configforge"
const VERSION := "1.0.0"
const SCHEMA_FORMAT := "configforge/1"

const EXIT_OK := 0
const EXIT_DATA := 1
const EXIT_SCHEMA := 2
const EXIT_USAGE := 3
const EXIT_INTERNAL := 4

var _pipeline := CFPipeline.new()
var _flags: Dictionary = {}
var _error_format := "json"
var _pretty := false
var _started := 0
var _booted := false


## 双入口兜底：`--script` 方式下 `_init` 与 `_initialize` 至少有一个会被调到，
## 先到的那个干活，另一个直接返回（避免重复执行与重复输出）。
func _init() -> void:
	_boot()


func _initialize() -> void:
	_boot()


func _boot() -> void:
	if _booted:
		return
	_booted = true
	_started = Time.get_ticks_msec()
	var code := _dispatch(OS.get_cmdline_user_args())
	quit(code)


# ---------------------------------------------------------------- 参数与分发

func _dispatch(args: PackedStringArray) -> int:
	var parsed := _parse_args(args)
	_flags = parsed.get("flags", {})
	# 先读输出格式，保证「参数解析失败」时也能按 --errorFormat=text 输出
	_error_format = str(_flags.get("errorformat", _flags.get("error_format", "json"))).to_lower()
	_pretty = bool(_flags.get("pretty", false))
	if parsed.has("error"):
		return _usage_error(str(parsed["error"]))
	var command := str(parsed.get("command", ""))

	var opts: Dictionary = {}
	if _flags.has("schema"):
		opts["schema_path"] = _norm_path(str(_flags["schema"]))
	if _flags.has("data"):
		opts["data_dir"] = _norm_path(str(_flags["data"]))
	if _flags.has("code_out"):
		opts["code_out_dir"] = _norm_path(str(_flags["code_out"]))
	if _flags.has("data_out"):
		opts["data_out_dir"] = _norm_path(str(_flags["data_out"]))
	if _flags.has("group"):
		opts["group"] = str(_flags["group"])
	_pipeline.configure(opts)

	if bool(_flags.get("help", false)) or command == "" or command == "help":
		_print_help()
		return EXIT_OK

	match command:
		"capabilities":
			return _cmd_capabilities()
		"list-tables":
			return _cmd_list_tables()
		"schema":
			return _cmd_schema()
		"describe":
			return _cmd_describe()
		"validate":
			return _cmd_validate()
		"generate":
			return _cmd_generate()
	return _usage_error("未知命令 %s" % command)


func _parse_args(args: PackedStringArray) -> Dictionary:
	var flags: Dictionary = {}
	var command := ""
	for raw in args:
		var a := str(raw).strip_edges()
		if a == "":
			continue
		if a == "--pretty":
			flags["pretty"] = true
			continue
		if a == "--dry-run":
			flags["dry_run"] = true
			continue
		if a == "--help" or a == "-h":
			flags["help"] = true
			continue
		if a.begins_with("--"):
			var body := a.substr(2)
			var key := body
			var value := "1"
			var eq := body.find("=")
			if eq >= 0:
				key = body.substr(0, eq)
				value = body.substr(eq + 1)
			key = key.replace("-", "_").to_lower()
			if key == "":
				return {"error": "无法解析参数 %s" % a}
			flags[key] = value
			continue
		if a.begins_with("-"):
			return {"error": "无法解析参数 %s" % a}
		if command == "":
			command = a.to_lower()
			continue
		return {"error": "多余的参数：%s（一个命令只接受一个子命令名）" % a}
	return {"command": command, "flags": flags}


func _norm_path(path: String) -> String:
	var s := path.strip_edges()
	if s == "":
		return s
	if s.begins_with("res://") or s.begins_with("user://"):
		return s
	if s.is_absolute_path():
		return s
	if s.begins_with("./"):
		s = s.substr(2)
	return "res://" + s


# ---------------------------------------------------------------- 子命令

func _cmd_capabilities() -> int:
	var res := _base_result("capabilities", EXIT_OK)
	res["capabilities"] = {
		"commands": ["capabilities", "list-tables", "schema", "describe", "validate", "generate"],
		"schemaFormat": SCHEMA_FORMAT,
		"sourceFormats": ["csv", "tsv", "json"],
		"outputs": ["gdscript", "json"],
		"dataLayouts": ["merged(config.json)", "per-table"],
		"features": [
			"enum", "bean", "inheritance", "polymorphism",
			"list", "set", "map", "nullable",
			"ref", "range", "length", "pattern", "resource-path",
		],
		"exitCodes": {"ok": EXIT_OK, "data": EXIT_DATA, "schema": EXIT_SCHEMA, "usage": EXIT_USAGE, "internal": EXIT_INTERNAL},
		"errorFormat": ["json", "text"],
	}
	_emit(res)
	return EXIT_OK


func _cmd_list_tables() -> int:
	if not _load_schema_or_fail("list-tables"):
		return EXIT_SCHEMA
	var data_ok := _pipeline.load_data()
	var issues: Array = []
	if not data_ok:
		# 数据坏了不能假装成功：Agent / CI 依赖退出码判断
		issues = _pipeline.validate()
	var list: Array = []
	for t in _pipeline.schema.tables:
		var name := str(t["name"])
		var loaded: Dictionary = _pipeline.tables.get(name, {})
		var count := 0
		if loaded.has("records"):
			count = loaded["records"].size()
		list.append({
			"name": name,
			"bean": str(t["bean_name"]),
			"input": str(t["input"]),
			"file": str(t["file_name"]),
			"source": str(t["source"]),
			"mode": str(t["mode"]),
			"index": str(t["index"]),
			"group": str(t["group"]),
			"member": str(t["member"]),
			"records": count,
			"comment": str(t["comment"]),
		})
	var exit_code := _code_for_stage("data", issues)
	var res := _base_result("list-tables", exit_code)
	res["tables"] = list
	res["stats"] = _pipeline.stats()
	res["issues"] = issues
	_emit(res)
	return exit_code


func _cmd_schema() -> int:
	if not _load_schema_or_fail("schema"):
		return EXIT_SCHEMA
	var res := _base_result("schema", EXIT_OK)
	res["schema"] = _pipeline.schema.to_agent_json()
	_emit(res)
	return EXIT_OK


func _cmd_describe() -> int:
	if not _load_schema_or_fail("describe"):
		return EXIT_SCHEMA
	var table_name := str(_flags.get("table", ""))
	if table_name == "":
		return _usage_error("describe 需要 --table=<表名>")
	var table := _pipeline.schema.table_by_name(table_name)
	if table.is_empty():
		return _usage_error("表 %s 不存在（可选：%s）" % [table_name, str(_pipeline.schema.table_names())])
	_pipeline.load_data()
	var loaded: Dictionary = _pipeline.tables.get(table_name, {})
	var records: Array = loaded.get("records", [])
	var sample: Array = []
	for i in range(min(3, records.size())):
		sample.append(records[i])
	var fields: Array = []
	for f in table["bean"]["fields"]:
		fields.append({
			"name": str(f["name"]),
			"type": str(f["type"]),
			"kind": str(f["kind"]),
			"comment": str(f["comment"]),
			"required": bool(f["required"]),
			"nullable": bool(f["info"].get("nullable", false)),
			"ref": str(f["ref"]),
			"min": f["min"],
			"max": f["max"],
			"sep": str(f["sep"]),
		})
	var res := _base_result("describe", EXIT_OK)
	res["table"] = {
		"name": table_name,
		"bean": str(table["bean_name"]),
		"input": str(table["input"]),
		"mode": str(table["mode"]),
		"index": str(table["index"]),
		"group": str(table["group"]),
		"records": records.size(),
		"fields": fields,
		"sample": sample,
	}
	_emit(res)
	return EXIT_OK


func _cmd_validate() -> int:
	var r := _pipeline.run({"generate": false})
	var issues: Array = r["issues"]
	var exit_code := _code_for_stage(str(r["stage"]), issues)
	var res := _base_result("validate", exit_code)
	res["stage"] = str(r["stage"])
	res["issues"] = issues
	res["logs"] = r["logs"]
	res["stats"] = r["stats"]
	_emit(res)
	return exit_code


func _cmd_generate() -> int:
	var dry := bool(_flags.get("dry_run", false))
	if dry:
		var vr := _pipeline.run({"generate": false})
		var issues: Array = vr["issues"]
		var exit_code := _code_for_stage(str(vr["stage"]), issues)
		var res := _base_result("generate", exit_code)
		res["dryRun"] = true
		res["stage"] = str(vr["stage"])
		res["issues"] = issues
		res["logs"] = vr["logs"]
		res["stats"] = vr["stats"]
		if exit_code == EXIT_OK:
			res["wouldWrite"] = _planned_files()
			# 顺手把生成文本渲一遍，汇报体积（不落盘），验证生成器本身没炸
			var preview := _pipeline.preview_code({"group": str(_flags.get("group", _pipeline.group))})
			res["previewBytes"] = {
				"schema_gd": str(preview.get("schema_gd", "")).length(),
				"loader_gd": str(preview.get("loader_gd", "")).length(),
			}
		_emit(res)
		return exit_code

	var r := _pipeline.run({"generate": true, "merge": _merge_flag()})
	var issues: Array = r["issues"]
	var exit_code := _code_for_stage(str(r["stage"]), issues)
	var res := _base_result("generate", exit_code)
	res["stage"] = str(r["stage"])
	res["issues"] = issues
	res["logs"] = r["logs"]
	res["files"] = r["files"]
	res["stats"] = r["stats"]
	_emit(res)
	return exit_code


## 数据是否合并成单文件：--merge=1|0（默认取管线当前设置，即 false = 每表一个文件）。
func _merge_flag() -> bool:
	if not _flags.has("merge"):
		return _pipeline.merge_data
	var v := str(_flags["merge"]).to_lower()
	return v != "0" and v != "false" and v != "no"


func _planned_files() -> Array:
	var out: Array = []
	out.append(_join(_pipeline.code_out_dir, "schema.gd"))
	out.append(_join(_pipeline.code_out_dir, "loader.gd"))
	if _merge_flag():
		out.append(_join(_pipeline.data_out_dir, _pipeline.data_file_name))
		return out
	for t in _pipeline.schema.tables_for_group(str(_flags.get("group", _pipeline.group))):
		out.append(_join(_pipeline.data_out_dir, str(t["file_stem"]) + ".json"))
	return out


# ---------------------------------------------------------------- 输出

func _base_result(command: String, exit_code: int) -> Dictionary:
	return {
		"ok": exit_code == EXIT_OK,
		"tool": TOOL,
		"version": VERSION,
		"command": command,
		"exitCode": exit_code,
		"dirs": _pipeline.dirs(),
		"stage": "",
		"issues": [],
		"logs": [],
		"files": [],
		"stats": {},
		"durationMs": 0,
	}


func _emit(result: Dictionary) -> void:
	var issues: Array = result.get("issues", [])
	result["errors"] = _by_severity(issues, CFIssue.ERROR)
	result["warnings"] = _by_severity(issues, CFIssue.WARNING)
	result["errorCount"] = result["errors"].size()
	result["warningCount"] = result["warnings"].size()
	result["durationMs"] = Time.get_ticks_msec() - _started
	result.erase("issues")

	if _error_format == "text":
		_emit_text(result)
	else:
		var indent := "\t" if _pretty else ""
		print(JSON.stringify(result, indent, false))


func _emit_text(result: Dictionary) -> void:
	var status := "OK" if bool(result.get("ok", false)) else "FAIL"
	print("[%s] %s %s (exit %d, %d ms)" % [
		TOOL, str(result.get("command", "")), status, int(result.get("exitCode", 0)), int(result.get("durationMs", 0))])
	var stats: Dictionary = result.get("stats", {})
	if not stats.is_empty():
		print("结构：%d 枚举 / %d 结构 / %d 表 / %d 条记录" % [
			int(stats.get("enums", 0)), int(stats.get("beans", 0)),
			int(stats.get("tables", 0)), int(stats.get("records", 0))])
	for it in result.get("errors", []):
		print("  " + CFIssue.format(it))
	for it in result.get("warnings", []):
		print("  " + CFIssue.format(it))
	for f in result.get("files", []):
		print("  写入：" + str(f))


func _by_severity(issues: Array, severity: String) -> Array:
	var out: Array = []
	for it in issues:
		if str(it.get("severity", "")) == severity:
			out.append(it)
	return out


func _code_for_stage(stage: String, issues: Array) -> int:
	if CFIssue.count_errors(issues) == 0:
		return EXIT_OK
	if stage == "schema":
		return EXIT_SCHEMA
	return EXIT_DATA


func _load_schema_or_fail(command: String) -> bool:
	if _pipeline.load_schema():
		return true
	var res := _base_result(command, EXIT_SCHEMA)
	res["stage"] = "schema"
	res["issues"] = _pipeline.schema.issues.duplicate()
	_emit(res)
	return false


func _usage_error(message: String) -> int:
	if _error_format == "json":
		var res := _base_result("", EXIT_USAGE)
		res["message"] = message
		res["durationMs"] = Time.get_ticks_msec() - _started
		var indent := "\t" if _pretty else ""
		print(JSON.stringify(res, indent, false))
	else:
		print("用法错误：" + message)
		print("运行 `-- --help` 查看用法，或 `-- capabilities` 查看能力清单。")
	return EXIT_USAGE


## 拼路径（委托 CFDataLoader.join_path，与管线和面板同一份实现）。
func _join(dir_path: String, name: String) -> String:
	return CFDataLoader.join_path(dir_path, name)


func _print_help() -> void:
	print("配置工坊 configforge %s — Godot 配置管线工具" % VERSION)
	print("")
	print("用法：godot --headless --path . --script res://addons/configforge/cli/cfg_cli.gd -- <命令> [参数]")
	print("")
	print("命令：")
	print("  capabilities            输出能力清单（命令、格式、退出码）")
	print("  list-tables             列出全部表与记录数")
	print("  schema                  输出机器可读 schema（JSON）")
	print("  describe --table=TbItem 输出单表字段与样例数据")
	print("  validate                校验结构与数据")
	print("  generate [--dry-run]    校验并生成 GDScript + 数据")
	print("")
	print("参数：")
	print("  --schema=<路径>         默认 res://configforge/schema.json")
	print("  --data=<目录>           默认 res://configforge/Data")
	print("  --code-out=<目录>       默认 res://configforge/cfg")
	print("  --data-out=<目录>       默认 res://configforge/data")
	print("  --group=<分组>          只导出包含该分组的表")
	print("  --merge=1|0             1 = 所有表合并成 data/config.json；0 = 每表一个 json（默认 0）")
	print("  --errorFormat=json|text 默认 json")
	print("  --pretty                JSON 缩进")
	print("")
	print("退出码：0 成功 / 1 数据或校验错误 / 2 结构错误 / 3 用法错误 / 4 内部错误（保留）")
