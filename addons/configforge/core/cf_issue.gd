@tool
class_name CFIssue
extends RefCounted

## 配置工坊 · 结构化问题
##
## 结构解析、数据加载、校验、生成四个环节共用同一种「问题对象」，
## 既供编辑器列表展示，也供 CLI 以 JSON 输出给 AI Agent / CI 消费
## （对应 Luban 5.0 的 --errorFormat json 与机器可读报错）。
##
## 问题对象形状：
##   {
##     severity: "error" | "warning",
##     code:     "E_ID_DUPLICATE" 一类的稳定机器码,
##     message:  人读说明,
##     where:    "[TbItem] 第 3 条·price" 定位前缀,
##     table:    表名,
##     row:      1 起的记录序号（0 表示整表/结构级问题）,
##     field:    字段名（结构级为空）,
##     file:     源文件路径,
##   }

const ERROR := "error"
const WARNING := "warning"


## 构造一个问题对象。opts 支持 table / row / field / where / file。
static func make(severity: String, code: String, message: String, opts: Dictionary = {}) -> Dictionary:
	var table := str(opts.get("table", ""))
	var row := 0
	var raw_row: Variant = opts.get("row", 0)
	if raw_row is int:
		row = raw_row
	elif raw_row is float:
		row = int(raw_row)
	var field := str(opts.get("field", ""))
	var where := str(opts.get("where", ""))
	if where == "":
		where = location(table, row, field)
	return {
		"severity": severity,
		"code": code,
		"message": message,
		"where": where,
		"table": table,
		"row": row,
		"field": field,
		"file": str(opts.get("file", "")),
	}


## 拼「[表] 第 N 条·字段」定位前缀；缺项自动省略。
static func location(table: String, row: int, field: String) -> String:
	var text := ""
	if table != "":
		text = "[%s]" % table
	if row > 0:
		if text != "":
			text += " "
		text += "第 %d 条" % row
	if field != "":
		if text != "":
			text += "·"
		text += field
	return text


## 单行文本形式，便于日志与终端阅读。
static func format(issue: Dictionary) -> String:
	var sev := str(issue.get("severity", ERROR))
	var where := str(issue.get("where", ""))
	var code := str(issue.get("code", ""))
	var head := "[%s] " % sev
	if where != "":
		head += where + "："
	var tail := ""
	if code != "":
		tail = "（%s）" % code
	return head + str(issue.get("message", "")) + tail


## 统计 error 数量（warning 不阻断生成）。
static func count_errors(list: Array) -> int:
	var n := 0
	for it in list:
		if it is Dictionary and str(it.get("severity", ERROR)) == ERROR:
			n += 1
	return n


## 统计 warning 数量。
static func count_warnings(list: Array) -> int:
	var n := 0
	for it in list:
		if it is Dictionary and str(it.get("severity", ERROR)) == WARNING:
			n += 1
	return n


## 去重（同 code + where + message 视为同一条，结构/数据两遍扫描可能重复报同一问题）。
static func dedupe(list: Array) -> Array:
	var seen := {}
	var out: Array = []
	for it in list:
		if not (it is Dictionary):
			continue
		var key := "%s|%s|%s" % [str(it.get("code", "")), str(it.get("where", "")), str(it.get("message", ""))]
		if seen.has(key):
			continue
		seen[key] = true
		out.append(it)
	return out


## 稳定排序：error 在前，其余按表名/行号/字段名排序，保证多次运行输出一致。
static func sorted(list: Array) -> Array:
	var out := list.duplicate()
	out.sort_custom(_compare)
	return out


## sort_custom 用的比较函数：error 优先，其次表名、行号、字段名。
static func _compare(a: Dictionary, b: Dictionary) -> bool:
	var sa := 0 if str(a.get("severity", ERROR)) == ERROR else 1
	var sb := 0 if str(b.get("severity", ERROR)) == ERROR else 1
	if sa != sb:
		return sa < sb
	var ta := str(a.get("table", ""))
	var tb := str(b.get("table", ""))
	if ta != tb:
		return ta < tb
	var ra := row_of(a)
	var rb := row_of(b)
	if ra != rb:
		return ra < rb
	return str(a.get("field", "")) < str(b.get("field", ""))


## 取问题里的 1 起行号；缺失/非数字一律当 0（结构级问题）。
static func row_of(issue: Dictionary) -> int:
	var v: Variant = issue.get("row", 0)
	if v is int:
		return v
	if v is float:
		return int(v)
	return 0
