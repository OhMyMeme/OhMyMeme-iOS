# OhMyMeme iOS

轻量化跨平台表情包管理系统的 iOS 端 — 与桌面端（[OhMyMeme](https://github.com/OhMyMeme/OhMyMeme)）、安卓端（[OhMyMeme-Android](https://github.com/OhMyMeme/OhMyMeme-Android)）存储结构一致，便于多端同步。

> 分发方式：**自签名（AltStore / SideStore）**。因经济原因不上架 App Store，产出 **未签名 ipa**，由高级用户安装时用个人免费 Apple ID 重签。

## 当前进度（Phase 1 MVP 已完成）

- [x] XcodeGen 工程脚手架（`project.yml` + 提交的 `.xcodeproj`）
- [x] 暗色壳主界面 + 应用图标 + Info.plist（文件共享 / 打开方式导入 / 本地网络权限）
- [x] ipa 构建脚本（未签名）+ GitHub Actions 自动构建
- [x] Phase 1 数据层：SQLite 7 表（与桌面端 `database.py` 一致）/ 配置 / Keychain 密钥加密 / 导入去重 / 缩略图 / 缓存扫描
- [x] Phase 1 主界面：3 列网格 / 搜索（防抖）/ 分组胶囊（含子分组展开）/ 收藏 / 最近使用 / 未分类 / 分页加载 / 拖拽排序
- [x] Phase 1 交互：分享 / 「⋯」菜单（重命名 / 收藏 / 分组 / 删除）/ 相册与文件导入 / 清空本地数据
- [x] 拖拽发送：长按拖动表情到微信/QQ 等聊天窗口直发原图（全 tab 可拖，拖拽预览；网格内重排保留）
- [x] Phase 1 设置页 + 单元测试（schema / SHA-256 / 魔数 / 去重 / 业务流）
- [ ] Phase 2（进行中）：复制处理与隐写 GIF、云端同步（FTP/S3/R2/WebDAV）、局域网互联、更新检查
  - [x] 复制处理模式 1/2（WebP 缩放 / 转 GIF，字节级对齐桌面端）
  - [x] 局域网互联客户端（UDP 发现 + HMAC-SHA256 挑战/应答 + AES-GCM 加密帧，协议对齐 `lan.py`；设置页「同步电脑表情」）
  - [x] 更新检查（GitHub Releases + 镜像，设置页「检查更新」）
  - [x] 云端同步（FTP/S3/R2/WebDAV，清单对齐 `sync.py`+`manifest.py`；设置页「云端同步配置与操作」）
  - [ ] 隐写 GIF（mode 3，依赖 XZ/LZMA2 方案）

## 环境要求

- macOS + Xcode 15+（编译 ipa 必须在 macOS 上进行）
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`；仓库已提交 `.xcodeproj`，没有 XcodeGen 也可直接打开）

## 构建 ipa

```bash
# 生成 .xcodeproj（首次或修改 project.yml 后）
./scripts/generate.sh

# 构建未签名 ipa，产物 dist/OhMyMeme-{版本}.ipa
./scripts/build-ipa.sh 0.1.0
```

CI：GitHub Actions（`.github/workflows/build.yml`）在 macOS runner 上自动构建，推 `v*` 标签或手动触发即可，产物为 artifact。

> 签名说明：脚本产出**未签名** ipa（`CODE_SIGNING_ALLOWED=NO`）。Xcode 16+ / iOS 18 SDK 已禁止 ad-hoc（`CODE_SIGN_IDENTITY="-"`）签名，而 AltStore/SideStore 安装时本就会用用户自己的 Apple ID 重签，因此无需任何证书 / 开发者账号。

## 分发：AltStore / SideStore 自签名安装

**高级用户安装步骤：**

1. 电脑安装 [AltServer](https://altstore.io/)（macOS 或 Windows 均可，iOS 15 需 AltServer 2.x）；手机装 [SideStore](https://sidestore.io/)（无需电脑续签）或 AltStore
2. 从 GitHub Releases 下载 `OhMyMeme-{版本}.ipa`
3. AltStore：手机连接电脑（同一 Wi-Fi，且电脑运行 AltServer）→ AltStore 内导入 ipa → 输入自己的免费 Apple ID → 自动签名安装
4. SideStore：无需电脑，用免费 Apple ID 在手机端直接签名安装

**自签名的限制（务必让用户知情）：**

- 签名 7 天过期：AltStore 需手机与电脑同一 Wi-Fi 时由 AltServer 自动续签；SideStore 需局域网内任一设备运行 SideStore Server
- 同一设备同时最多安装 3 个自签应用
- 不支持推送 / iCloud 等需要特殊 entitlement 的能力（本项目不需要）
- 若后续获得 $99/年 开发者账号，可平滑切换为 Ad Hoc 签名（登记用户 UDID，100 台/年），构建流程不变

## 仓库结构

```
OhMyMeme-iOS/
├── project.yml                    # XcodeGen 工程定义（min iOS 15，bundle id com.ohmymeme.app）
├── OhMyMeme.xcodeproj             # 生成后提交，方便直接打开构建
├── OhMyMeme/
│   ├── App/                       # 入口、主界面、设置页（Phase 1）
│   ├── Data/                      # 数据库/配置/导入/缩略图（Phase 1）
│   ├── Image/                     # GIF/WebP/隐写（Phase 2）
│   ├── Sync/                      # 云端同步/局域网/更新（Phase 2）
│   └── Resources/                 # Info.plist、Assets
├── OhMyMemeTests/                 # XCTest
├── scripts/                       # generate.sh / build-ipa.sh
└── .github/workflows/build.yml    # macOS runner 出未签名 ipa
```

## 技术栈

| 模块 | 技术 | 理由 |
|------|------|------|
| 语言/UI | Swift + UIKit + UICollectionView | 与安卓端 RecyclerView 对齐，iOS 15+ |
| 数据库 | 系统 SQLite3 + 薄封装 | schema 与桌面端 `database.py` 逐列一致 |
| 加密 | CryptoKit + Keychain | 配置密钥字段 AES-GCM 加密 |
| 图片 | SDWebImage + SDWebImageWebPCoder（SPM） | GIF 动图播放 / WebP 解码 / 网格降采样缓存 |
| 同步 | URLSession + Network.framework | Phase 2 |

## 许可证

GPL-3.0