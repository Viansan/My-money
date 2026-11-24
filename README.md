# 我的资产 (MyMoney) — 极简原生 iOS 个人资产管理 App

基于 **SwiftUI + SwiftData + Swift Charts** 构建的纯本地 iOS 个人资产盘点与结构管理工具（最低支持 **iOS 17.0**，零第三方依赖，无需后端服务器）。

---

## 一、核心设计特性

1. **「投资资产」与「固定资产」彻底解耦**
   - 每个资产类别可自由指定归属于 **投资资产** 或 **固定资产**。
   - 大额定期存单（如 100 万定期）、房产、公积金等归入「固定资产」后，**计入全部总净值，但绝不稀释日常投资组合的配置占比环形图与目标对比**。
2. **「资产类别 + 存放账户」双维度管理与下钻**
   - 自由增删改排序 **资产类别** 与 **存放账户**；在「总览」页轻点任意分类或账户卡片即可直接下钻到「资产」页对应明细（支持一键收回显示全部）。
   - 在「资产」页支持一键切换 **按类别** 与 **按账户对账**——按账户聚合时合并该平台下的投资与固定资金总额，方便直接对照真实银行/券商 App 核对账面数字。
3. **把复杂留给系统：代码自动识别 + 快捷调数**
   - **录入仅需二选一（「按金额」vs「证券 / 基金」）**：输入代码停顿 0.45 秒自动分辨沪深京 ETF/股票、港股、美股或场外基金（含债基与 QDII），自动填好名称、现价/官方净值与日期；仅在极少数真实重码（如 `000001` 或 LOF 基金）时提供一键切换。
   - **快捷调数**：轻点持仓呼出快速调数面板，支持实时预览变化量、一键步进胶囊（`+100份`/`+1万` 等）、现价估算本金，右滑列表行可直接单条刷新行情。
   - **静默自动刷价**：打开或回到 App 时若行情超过 5 分钟未更新，后台静默刷新，无需手动下拉。
4. **选填目标占比 & 选填成本盈亏**
   - **目标占比（可选）**：投资类别可自愿设置参考目标占比（支持一键填入剩余百分比），总览页展示实际占比与目标偏差；不填则清爽展示实际金额与比例。
   - **持仓成本（可选）**：单笔资产可自愿填写「累计投入本金」或「持仓成本单价」，自动计算持仓盈亏与收益率（未填成本的现金类不会混入盈亏分母）。
5. **100% 本地隐私、可撤销删除与离线 JSON 备份**
   - 删除资产后提供 **5 秒底部浮层「撤销」**，全 App 统一非阻塞 Toast 与触觉反馈；恢复 JSON 备份前自动预检并展示备份时间与条数摘要。

---

## 二、目录结构

```text
My-money/
├── MyMoney.xcodeproj/              # 标准 Xcode 工程文件（双击直接打开，无需额外工具）
├── project.yml                     # 可选 XcodeGen 配置文件
└── MyMoney/
    ├── App/
    │   └── MyMoneyApp.swift        # App 入口与 SwiftData ModelContainer 初始化
    ├── Models/
    │   ├── AssetEnums.swift        # 资金池、计价模式、配色、盈亏色系与图标预设
    │   ├── AssetCategory.swift     # 资产类别模型（含投资/固定归属与可选目标占比）
    │   ├── AssetAccount.swift      # 存放账户/渠道模型
    │   ├── AssetHolding.swift      # 具体资产持仓模型（含可选成本与市值计算）
    │   └── BackupPayload.swift     # JSON 导入导出 DTO 与 FileDocument 封装
    ├── Services/
    │   ├── PriceService.swift      # 智能代码识别与并发行情服务（TaskGroup + 三级容错）
    │   ├── PortfolioAnalytics.swift# 双池隔离资产聚合与盈亏核算引擎
    │   └── DataBackupService.swift # 默认基础字典初始化、演示数据与 JSON 预检/恢复
    ├── ViewModels/
    │   └── PortfolioRefreshStore.swift # @Observable 全局状态、静默刷价、下钻与撤销协调器
    ├── Views/
    │   ├── RootTabView.swift       # 3-Tab 主框架、前台自动刷新与全局浮层 Toast
    │   ├── Overview/               # 总净值卡片、双池切换、可交互 SectorMark 环形图与下钻卡片
    │   ├── Holdings/               # 双维度列表、快速调数抽屉、二选一智能新增/编辑表单
    │   ├── Management/             # 类别/账户字典 CRUD、拖拽排序、偏好与安全 JSON 备份
    │   └── Components/             # Formatters 格式化、Haptics 触觉反馈、ToastBannerView
    └── Resources/
        ├── Info.plist              # 应用显示名（我的资产）、全屏启动与 HTTPS 网络配置
        └── Assets.xcassets/        # 原生应用图标 AppIcon 与自适应主题色
```

---

## 三、Xcode 真机编译与安装指南（最小配置）

1. **打开工程**
   - 在 Mac（Xcode 15.0 或更高版本）上克隆本仓库，双击打开 `MyMoney.xcodeproj`。
2. **配置真机签名（Signing & Capabilities）**
   - 在左侧导航栏点击顶层蓝色的 **MyMoney** 工程图标 -> 选中 `TARGETS` 下的 **MyMoney** -> 切换到 **Signing & Capabilities** 标签页：
   - 勾选 `Automatically manage signing`；
   - 在 **Team** 下拉框中选择你的 Apple ID 团队；
   - 将 **Bundle Identifier** 修改为你个人唯一的标识（例如 `com.你的名字.mymoney`）。
3. **连接 iPhone 运行**
   - 用数据线连接 iPhone（iOS 17.0 及以上），在 Xcode 顶部设备栏选择你的真机，按下 `Cmd + R` 编译安装。
   - *首次使用个人免费 Apple ID 真机安装提示*：若 iPhone 提示“不受信任的开发者”，前往 iPhone **设置 -> 通用 -> VPN 与设备管理**，点击你的开发者账号选择**信任**即可打开（注：Apple 免费个人签名每 7 天需连 Xcode 重签一次，重签直接覆盖安装不会丢失本地数据；付费开发者账号签名有效期为 1 年）。
