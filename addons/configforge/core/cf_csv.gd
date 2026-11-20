@tool
class_name CFCsv
extends RefCounted

## 配置工坊 · CSV 读写
##
## 只负责「文本 ⇄ 二维字符串数组」，不掺业务语义：
## 表头行（##var / ##type / ##comment / ##group）的解读放在 CFDataLoader，
## 这样同一份解析器既能读数据，也能读导入文件、写回源文件。
##
## 兼容：UTF-8 BOM、CRLF / LF、双引号转义（""）、引号内换行、
## 单元格首尾空格保留（不加引号也不会被裁掉）。

const DEFAULT_SEP := ","


## 文本 → 行数组（每行是字符串数组）。空文本返回 []。
static func parse(text: String, sep: String = DEFAULT_SEP) -> Array:
	var rows: Array = []
	var row: Array = []
	var cell := ""
	var src := text
	if src.length() > 0 and src.unicode_at(0) == 0xFEFF:
		src = src.substr(1)
	var n := src.length()
	var i := 0
	var in_quotes := false
	var cell_started := false
	while i < n:
		var ch: String = src[i]
		if in_quotes:
			if ch == "\"":
				if i + 1 < n and src[i + 1] == "\"":
					cell += "\""
					i += 2
					continue
				in_quotes = false
				i += 1
				continue
			cell += ch
			i += 1
			continue
		if ch == "\"" and not cell_started:
			in_quotes = true
			cell_started = true
			i += 1
			continue
		if ch == sep:
			row.append(cell)
			cell = ""
			cell_started = false
			i += 1
			continue
		if ch == "\r" or ch == "\n":
			if ch == "\r" and i + 1 < n and src[i + 1] == "\n":
				i += 1
			row.append(cell)
			rows.append(row)
			row = []
			cell = ""
			cell_started = false
			i += 1
			continue
		cell += ch
		cell_started = true
		i += 1
	# 末行无换行符时也要收尾；以换行结尾时不额外产生空行
	if cell_started or cell != "" or not row.is_empty():
		row.append(cell)
		rows.append(row)
	return rows


## 行数组 → 文本（末尾带一个换行符）。
static func stringify(rows: Array, sep: String = DEFAULT_SEP) -> String:
	var lines: Array = []
	for r in rows:
		if not (r is Array):
			continue
		var cells: Array = []
		for c in r:
			cells.append(escape_cell(str(c), sep))
		lines.append(sep.join(cells))
	if lines.is_empty():
		return ""
	return "\n".join(lines) + "\n"


## 单元格转义：含分隔符 / 引号 / 换行时用双引号包裹，内部引号写成 ""。
static func escape_cell(value: String, sep: String = DEFAULT_SEP) -> String:
	if value.contains("\"") or value.contains(sep) or value.contains("\n") or value.contains("\r"):
		return "\"" + value.replace("\"", "\"\"") + "\""
	return value


## 去掉 UTF-8 BOM。Excel / 记事本导出的 CSV、部分编辑器存的 JSON 都会带 BOM，
## JSON.parse_string 遇到 BOM 会直接失败，所以读文件后先过一下这个。
static func strip_bom(text: String) -> String:
	if text.length() > 0 and text.unicode_at(0) == 0xFEFF:
		return text.substr(1)
	return text


## 按文件名猜分隔符（.tsv 用制表符，其余逗号）。
static func sep_for_file(path: String) -> String:
	if path.to_lower().ends_with(".tsv"):
		return "\t"
	return DEFAULT_SEP


## 读文件 → { ok, rows, error }。文件不存在按空表处理（由上层决定是否报错）。
static func read_file(path: String, sep: String = DEFAULT_SEP) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "rows": [], "error": "文件不存在：%s" % path}
	var text := FileAccess.get_file_as_string(path)
	if text == "" and FileAccess.get_open_error() != OK:
		return {"ok": false, "rows": [], "error": "无法读取文件：%s" % path}
	return {"ok": true, "rows": parse(text, sep), "error": ""}


## 写文件（UTF-8 无 BOM）→ { ok, error }。
static func write_file(path: String, rows: Array, sep: String = DEFAULT_SEP) -> Dictionary:
	var dir := path.get_base_dir()
	if dir != "" and not DirAccess.dir_exists_absolute(dir):
		var mk := DirAccess.make_dir_recursive_absolute(dir)
		if mk != OK:
			return {"ok": false, "error": "无法创建目录 %s（err=%d）" % [dir, mk]}
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "无法写入文件 %s" % path}
	file.store_string(stringify(rows, sep))
	file.close()
	return {"ok": true, "error": ""}
