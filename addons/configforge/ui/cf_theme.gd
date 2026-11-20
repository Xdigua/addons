@tool
class_name CFTheme
extends RefCounted

## 兼容占位类。
##
## 界面皮肤（字号 / 配色）已经并入 ui/dock_main.gd 的 _make_theme()，
## 面板不再依赖这个类。保留 class_name 只是为了：
##   1. 旧版本生成物或外部脚本里可能还写着 CFTheme，不至于直接报「未声明」；
##   2. 让 .godot 的全局类缓存保持稳定。
##
## 这里刻意不放任何方法/常量，避免成为一个可能出错的依赖。
