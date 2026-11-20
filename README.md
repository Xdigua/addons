# 配置工坊 ConfigForge · 插件包

可以直接拷进任意 Godot 4 项目的插件包，只包含运行插件必需的文件。

插件在宿主工程里**只创建 `configforge/` 一个目录**，不会碰你原有的任何目录。

## 安装

1. 把本目录下的 `addons/` 整个文件夹拷到目标项目根目录（与 `project.godot` 同级）：

   ```
   你的项目/
   ├── project.godot
   ├── addons/
   │   └── configforge/
   │       ├── plugin.cfg
   │       ├── plugin.gd
   │       ├── core/  ui/  cli/  defaults/
   └── （其余目录保持原样）
   ```

2. 打开 Godot → **项目 → 项目设置 → 插件** → 勾选「配置工坊 ConfigForge」。
3. 首次启用会自动做三件事：
   - 把 `defaults/` 铺到 `res://configforge/`（`schema.json` + `data/*.json`，**已有文件不会被覆盖**）；
   - 以**浮窗**打开面板；
   - 跑一次生成，产出 `res://configforge/out/`。

## 启用后的目录

```
你的项目/
├── addons/configforge/        ← 插件本体
└── configforge/               ← 插件的全部文件都在这里
    ├── schema.json            结构定义（源）
    ├── data/                  数据源（源，手写或导入）
    │   ├── item.json
    │   ├── monster.json
    │   ├── skill.json
    │   ├── drop.json
    │   └── .gdignore
    └── out/                   生成物（首次生成后出现）
        ├── schema.gd
        ├── loader.gd
        └── tb*.json
```

不想用插件了：删掉 `addons/configforge/` 和 `configforge/` 两个目录即可，项目其它部分不受影响。

## 包里有什么

| 路径 | 必需 | 作用 |
|---|---|---|
| `plugin.cfg` | 是 | Godot 识别插件的入口 |
| `plugin.gd` | 是 | 插件生命周期、浮窗/侧栏承载、菜单项 |
| `core/*.gd` | 是 | 管线：类型、CSV、schema、加载、校验、生成、编排（纯逻辑，无编辑器依赖） |
| `ui/dock_main.gd` | 是 | 面板本体（纯代码构建） |
| `ui/cf_theme.gd` | 是 | 占位类，插件的依赖自检会加载它 |
| `cli/cfg_cli.gd` | 否 | headless CLI；不用命令行/Agent 可以删 |
| `defaults/schema.json` | 建议 | 首次启用时铺到 `configforge/` 的示例结构（2 枚举 / 8 结构 / 4 表） |
| `defaults/data/*.json` | 建议 | 示例数据源，当前是**空数组**，即四张表都没有记录 |
| `defaults/data/.gdignore` | **是** | 让 Godot 的文件扫描跳过数据目录，避免 CSV 被当成翻译表导入 |

## 初始状态

- `schema.json` 保留了完整的示例结构（枚举、继承与多态、list/map、ref 约束），可以直接当模板改；
- 四张表的数据源都是 `[]`，**没有任何记录**，从「新增行」或「导入…」开始填。

## 开始使用

1. 面板「结构」页：改字段名/类型、增删字段/枚举/表；
2. 面板「表数据」页：`新增行` 或 `导入…`（支持外部 JSON / CSV，可替换可追加）；
3. 点 `保存结构` / `保存表` 写回 `configforge/`；
4. 点 `一键生成` 产出 `configforge/out/`；
5. 业务代码：

   ```gdscript
   var tables: Schema.CfgTables = CfgLoader.load_tables()
   for item in tables.tbItem.get_data_list():
       print(item.id, item.name)
   ```

## 依赖

- Godot 4.x（开发验证版本 4.7.2）；
- 不依赖任何其它插件或 GDExtension；
- 面板与 CLI 共用同一套 `core/`，两边判定一致。

## 注意

- `configforge/data/.gdignore` 不要删：删了之后 Godot 会把 `*.csv` 当「CSV 翻译表」导入，
  表头里的 `|` 会生成非法文件名导致导入反复报错；
- 包里的脚本没有 `.uid` 文件，Godot 首次打开会自动生成，属正常现象。

更详细的操作说明见工程根目录的 `README.md`，内部实现见 `docs/technical.md`。
