# 我的资产 (MyMoney) — 极简原生 iOS 个人资产管理 App

基于 **SwiftUI + SwiftData + Swift Charts** 构建的纯本地 iOS 个人资产盘点与结构管理工具（最低支持 **iOS 17.0**，零第三方依赖，无需后端服务器）。

---

## 一、核心设计特性

1. **「投资资产」与「固定/底仓资产」彻底解耦**
   - 每个资产类别可自由指定归属于 **投资资产池** 或 **固定/底仓池**。
   - 大额定期存单（如 100 万底仓）、房产、公积金等归入「固定/底仓」后，**计入全部总净值，但绝不稀释日常投资组合的配置占比环形图与目标对比**。
2. **「资产类别 + 存放账户」双维度管理**
   - 自由增删改排序 **资产类别**（如：境内权益、海外指数、债券固收、大额底仓）与 **存放账户**（如：某券商、某银行、某基金平台）。
   - 在「资产」页支持一键切换 **按类别查看** 与 **按账户对账**——按账户聚合时合并该平台下的投资与固定资金总额，方便直接对照真实银行/券商 App 核对账面数字。
3. **灵活计价与联网行情自动识别**
   - **直接填金额**：适用于现金、活期、定期存单、银行理财、不动产等。
   - **场内证券**：支持沪深京 ETF/股票、港股、美股代码自动识别名称与最新价（腾讯财经接口，`GB18030` 解码 + 早盘 `0.000` 竞价回退昨收保护）。
   - **场外基金**：支持国内公募、债券基金及美股 QDII 基金拉取最新**官方单位净值**与净值日期（腾讯场外接口 + 东方财富移动端/历史净值三级自动兜底）。
   - 所有联网资产均保留**手动改单价**兜底，轻点列表行即可呼出「快速调数面板」（支持直接改总量或 `±` 增减变动）。
4. **选填目标占比 & 选填成本盈亏**
   - **目标占比（可选）**：投资类别可自愿设置参考目标占比，总览页展示实际占比与目标偏差；不填则仅清爽展示实际金额与比例。
   - **持仓成本（可选）**：单笔资产可自愿填写「累计投入本金」或「持仓成本单价」，自动计算持仓盈亏与收益率（未填成本的现金类不会混入盈亏分母）。
5. **100% 本地隐私与离线 JSON 备份**
   - 全部数据存储于本机 SwiftData SQLite 数据库，支持一键导出带时间戳的 `.json` 备份文件及从备份完整恢复。

---

## 二、目录结构

```text
My-money/
├── MyMoney.xcodeproj/              # 标准 Xcode 工程文件（双击直接打开，无需安装额外工具）
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
    │   ├── PriceService.swift      # 异步并发行情与净值服务（TaskGroup + 三级容错）
    │   ├── PortfolioAnalytics.swift# 双池隔离资产聚合与盈亏核算引擎
    │   └── DataBackupService.swift # 默认基础字典初始化、演示数据与 JSON 备份恢复
    ├── ViewModels/
    │   └── PortfolioRefreshStore.swift # @Observable 行情刷新状态与偏好设置存储
    ├── Views/
    │   ├── RootTabView.swift       # 3-Tab 主框架（总览 / 资产 / 管理）
    │   ├── Overview/               # 总净值卡片、双池切换、SectorMark 环形图与占比明细
    │   ├── Holdings/               # 双维度列表、快速调数面板、完整新增/编辑表单
    │   ├── Management/             # 类别/账户字典 CRUD、拖拽排序、偏好与 JSON 备份
    │   └── Components/             # 金额、份额、百分比格式化与解析工具
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
