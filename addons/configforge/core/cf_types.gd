@tool
class_name CFTypeSystem
extends RefCounted

## 配置工坊 · 类型系统
##
## Luban 的设计哲学是「类型系统才是配置工具的核心」：解析任意源格式只是
## 「按类型定义把数据读出来」。因此类型解析独立成一薄层，供 schema 解析、
## 数据加载、校验、代码生成、UI 五处共用，避免各自写一遍类型判断。
##
## 支持的写法：
##   int | long | int32 | int64 | short | byte      -> int（Godot int 为 64 位）
##   float | double | number                        -> float
##   bool | boolean                                 -> bool
##   string | str                                   -> string
##   EnumName                                       枚举
##   BeanName                                       结构（可嵌套）
##   list,T / array,T / set,T                       容器（set 额外做去重校验）
##   map,K,V                                        字典（key 限标量/枚举）
##   T?                                             可空（空值合法，导出为 null）
##
## 容器与 map 允许嵌套（如 list,list,int、map,string,list,Effect）。

const SCALARS := ["int", "float", "bool", "string"]


## 解析类型字符串。返回：
##   { ok, error, raw, nullable, kind, type, elem, key, value, is_set }
## kind ∈ scalar / enum / bean / list / map；容器信息嵌套在 elem / key / value 里。
static func parse_type(raw: String, enums: Dictionary, beans: Dictionary) -> Dictionary:
	var info := {
		"ok": false,
		"error": "",
		"raw": str(raw),
		"nullable": false,
		"kind": "",
		"type": "",
		"elem": {},
		"key": {},
		"value": {},
		"is_set": false,
	}
	var s := str(raw).strip_edges()
	info["raw"] = s
	if s == "":
		info["error"] = "类型为空"
		return info

	if s.ends_with("?"):
		info["nullable"] = true
		s = s.substr(0, s.length() - 1).strip_edges()
		if s == "":
			info["error"] = "可空标记 ? 前缺少类型"
			return info

	# String.split 返回 PackedStringArray，这里显式转成 Array 便于后续按索引改写
	var parts: Array = []
	for piece in s.split(","):
		parts.append(str(piece).strip_edges())

	var head := str(parts[0]).to_lower()
	if head == "list" or head == "array" or head == "set":
		info["kind"] = "list"
		info["is_set"] = (head == "set")
		var rest := _join_parts(parts, 1)
		if rest == "":
			info["error"] = "容器 %s 缺少元素类型（应形如 list,int）" % head
			return info
		var elem := parse_type(rest, enums, beans)
		if not elem["ok"]:
			info["error"] = "list 元素类型非法：%s" % str(elem["error"])
			return info
		info["elem"] = elem
		info["ok"] = true
		return info

	if head == "map" or head == "dict" or head == "dictionary":
		info["kind"] = "map"
		if parts.size() < 3:
			info["error"] = "map 需要键与值两个类型（应形如 map,string,int）"
			return info
		var key := parse_type(str(parts[1]), enums, beans)
		if not key["ok"]:
			info["error"] = "map 键类型非法：%s" % str(key["error"])
			return info
		if not (str(key["kind"]) == "scalar" or str(key["kind"]) == "enum"):
			info["error"] = "map 键只支持标量或枚举，实际为 %s" % str(key["raw"])
			return info
		var val := parse_type(_join_parts(parts, 2), enums, beans)
		if not val["ok"]:
			info["error"] = "map 值类型非法：%s" % str(val["error"])
			return info
		info["key"] = key
		info["value"] = val
		info["ok"] = true
		return info

	# 单类型：标量 / 枚举 / 结构
	var token := str(parts[0])
	var scalar := normalize_scalar(token)
	if scalar != "":
		info["kind"] = "scalar"
		info["type"] = scalar
		info["ok"] = true
		return info
	if enums.has(token):
		info["kind"] = "enum"
		info["type"] = token
		info["ok"] = true
		return info
	if beans.has(token):
		info["kind"] = "bean"
		info["type"] = token
		info["ok"] = true
		return info

	info["error"] = "未知类型 %s（既不是标量，也不是已定义的枚举/结构）" % token
	return info


## 标量别名归一：返回 "" 表示不是标量。
static func normalize_scalar(token: String) -> String:
	match token.to_lower():
		"int", "long", "int32", "int64", "short", "byte", "ushort", "uint", "ulong":
			return "int"
		"float", "double", "number", "decimal":
			return "float"
		"bool", "boolean":
			return "bool"
		"string", "str", "text":
			return "string"
	return ""


## 拼接 parts[from..] 还原嵌套类型字符串（如 ["list","list","int"] -> "list,int"）。
static func _join_parts(parts: Array, from: int) -> String:
	var out: Array = []
	for i in range(from, parts.size()):
		out.append(str(parts[i]))
	return ",".join(out)


## 字段类型默认值：用于「新增行」与坏数据的占位，保证 UI 永远能显示。
static func default_value(info: Dictionary, enums: Dictionary) -> Variant:
	if bool(info.get("nullable", false)):
		return null
	match str(info.get("kind", "")):
		"scalar":
			match str(info.get("type", "")):
				"int":
					return 0
				"float":
					return 0.0
				"bool":
					return false
				_:
					return ""
		"enum":
			var edef: Variant = enums.get(str(info.get("type", "")), null)
			if edef is Dictionary:
				var values: Dictionary = edef.get("values", {})
				if not values.is_empty():
					return values.values()[0]
			return 0
		"list":
			return []
		"map":
			return {}
		"bean":
			return {}
	return null


## 生成代码用的 GDScript 类型标注。容器生成嵌套 Array[...]；enum 用 int；map 用 Dictionary。
static func gd_type(info: Dictionary) -> String:
	match str(info.get("kind", "")):
		"scalar":
			match str(info.get("type", "")):
				"int":
					return "int"
				"float":
					return "float"
				"bool":
					return "bool"
				_:
					return "String"
		"enum":
			return "int"
		"bean":
			return str(info.get("type", ""))
		"list":
			var elem: Dictionary = info.get("elem", {})
			var elem_gd := gd_type(elem)
			if elem_gd == "Variant":
				return "Array"
			return "Array[%s]" % elem_gd
		"map":
			return "Dictionary"
	return "Variant"


## 是否数值类型（min/max 校验只对数值生效）。
static func is_numeric(info: Dictionary) -> bool:
	if str(info.get("kind", "")) != "scalar":
		return false
	var t := str(info.get("type", ""))
	return t == "int" or t == "float"


## 数字转文本：整数不带 .0，避免 CSV / 面板里出现 1.0 这种噪声。
## （loader 写单元格、validator 拼约束、面板显示都走这一个，别再各写一份。）
static func number_text(value: Variant) -> String:
	if value is int:
		return str(value)
	if value is float:
		if float(value) == float(int(value)):
			return str(int(value))
		return str(value)
	return str(value)


## 单值 → 展示文本：null 空串、bool 写 true/false、数字走 number_text。
static func scalar_text(value: Variant) -> String:
	if value == null:
		return ""
	if value is bool:
		return "true" if value else "false"
	return number_text(value)


## 稳定类型 ID（FNV-1a 32 位有符号），写入生成代码的 __type_id__。
## 与 Luban 官方产物的数值不保证逐位相同，仅供本工具链内部做类型标识。
static func type_id(type_name: String) -> int:
	var h := 2166136261
	for i in range(type_name.length()):
		h = h ^ type_name.unicode_at(i)
		h = (h * 16777619) & 0xFFFFFFFF
	if h >= 0x80000000:
		h -= 0x100000000
	return h
