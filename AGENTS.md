# OhMyMeme iOS — AI Agent Guide

## 项目概述
桌面端表情包管理系统（OhMyMeme）的 iOS 端。存储结构、数据库 schema、导入/扫描/缩略图命名规则与桌面端 `https://github.com/OhMyMeme/OhMyMeme` 完全一致，便于多端同步。

> 分发方式：**自签名（AltStore / SideStore）**。因经济原因不上架 App Store，产出 **未签名 ipa**，由高级用户安装时用个人免费 Apple ID 重签。Xcode 16+ / iOS 18 SDK 已禁止 ad-hoc 签名（`CODE_SIGN_IDENTITY="-"`），故 `build-ipa.sh` 用 `CODE_SIGNING_ALLOWED=NO` 出未签名包。

## 架构
```
AppDelegate / MainViewController / SettingsViewController
        │ 调用
AppContext.shared.queue（串行后台队列跑 DB/IO，UI 回主线程）
MemeDb (SQLite3 薄封装) ──► Documents/data/memes.db
StoragePaths              ──► Documents/config.json、Documents/data/
ConfigStore + CryptoUtil + Keychain ──► 密钥字段 AES-GCM 加密
    CacheScanner / MemeImporter / Thumbnailer ──► Documents/data/cache/、thumbnails/
    CloudSync ──► 远端 memes/ + meme-index.json（FTP/S3/R2/WebDAV）
    LanClient  ──► 桌面端 lan.py（UDP 发现 + TCP 握手 + AES-GCM 会话）
    UpdateChecker ──► GitHub Releases API + 镜像
```

## 技术栈
- **Swift 5.9 + UIKit** + UICollectionView / UITableView（与安卓端 RecyclerView 对齐，iOS 15+）
- **系统 SQLite3** + 薄封装（`SQLiteDatabase.swift`），schema 与桌面端 `database.py` 逐列一致
- **CryptoKit + Keychain**：配置密钥字段 AES-GCM 加密（桌面端 Fernet，安卓端 Keystore，格式不互通但字段名一致）
- **SDWebImage + SDWebImageWebPCoder**（SPM）：GIF 动图播放 / WebP 解码 / 网格降采样缓存
- **XcodeGen**（`project.yml`），生成的 `OhMyMeme.xcodeproj` 提交入库
- **URLSession + POSIX socket（FTP）** 做云同步；Network.framework 未用，局域网用 POSIX socket
- min iOS 15.0，TARGETED_DEVICE_FAMILY=1（仅 iPhone），bundle id `com.ohmymeme.app`

## 核心原则
- **不重构桌面端** — 桌面端 `https://github.com/OhMyMeme/OhMyMeme` 仅做最小必要修改；如需同步桌面端数据层逻辑，以 `database.py`/`config.py`/`webui.py` 为唯一事实来源
- **存储结构对齐桌面端** — 表 schema、列名、重命名规则、缩略图命名、去重逻辑逐条对照，不得随意改动
- **增改同步** — 新功能/新文件必须同步更新 `README.md` 和 `AGENTS.md`
- **无 emoji**（除非用户要求）
- **代码风格** — 无冗余注释；`AppContext.shared.queue` 串行后台队列跑数据库/IO，UI 更新回主线程；中文注释沿用现有文件风格
- **iOS 15 兼容陷阱** — `NSLock.withLock` 是 iOS 16+ API，**禁止使用**，一律 `lock.lock(); defer { lock.unlock() }`；避免 iOS 16+ 的 API（如 `UIPasteControl` 等）

## 构建 & 验证
```bash
./scripts/generate.sh        # 首次或修改 project.yml 后重新生成 .xcodeproj（需 macOS + xcodegen）
./scripts/build-ipa.sh 0.1.0 # 未签名 ipa，产物 dist/OhMyMeme-{版本}.ipa（需 macOS）
```
- **必须在 macOS 上编译验证**（Windows 无法编译 Swift）。改动后先本地 `xcodebuild test` 跑 `OhMyMemeTests`，再出包
- **XcodeGen 目录通配**：`project.yml` 用目录 source，新增 .swift 文件后需在 Mac 上重新 `xcodegen generate` 才会进工程
- 脚本统一 LF 换行（`.gitattributes` 中 `*.sh text eol=lf`）
- 新文件在 `OhMyMeme/` 各子目录（App/Data/Image/Sync），测试放 `OhMyMemeTests/`

## CI（.github/workflows/build.yml）
- macOS 15 runner：`workflow_dispatch` 或 push `v*` 标签触发，`brew install xcodegen` → `bash ./scripts/build-ipa.sh "$VERSION"` → 上传 `dist/*.ipa` artifact
- 版本号取 `GITHUB_REF_NAME#v`

## 关键目录
```
OhMyMeme/
  App/
    AppDelegate.swift        # 入口；文件共享/打开方式导入（CFBundleDocumentTypes public.image）
    AppContext.swift         # 共享上下文：串行后台队列 + db + config（含 dataChanged/configChanged 通知）
    MainViewController.swift # 主界面：3 列网格/搜索防抖/分组胶囊/收藏/最近/未分类/分页/拖拽重排/拖拽发送
    MemeGridCell.swift       # 网格单元格（含 currentImage 供拖拽预览）
    ChipCell.swift           # 分组胶囊单元格（isSelected 需 override）
    SettingsViewController.swift # 设置页：配置/复制处理/局域网互联/云端同步/更新检查/清空
    UIColor+Hex.swift        # 暗色配色 hex 扩展
  Data/
    Meme.swift               # 数据模型（对应 memes 表，含 stegoOfHash/fromStego）
    MemeDb.swift             # SQLite 封装（7 表 + 索引 + 列迁移 + 分组树/搜索/排序）
    SQLiteDatabase.swift     # SQLite3 C API 薄封装
    ConfigStore.swift        # JSON 配置（DEFAULTS 与桌面端 config.py 一致）+ 密钥字段标记
    CryptoUtil.swift         # Keychain AES-GCM 加解密
    StoragePaths.swift       # 路径解析（Documents/config.json、Documents/data/…）
    FileUtils.swift          # SHA-256 + 魔数识别扩展名 + stem
    CacheScanner.swift       # 缓存扫描（双重去重）
    MemeImporter.swift       # 导入（去重/魔数/尺寸/入库；STG3 还原）
    Thumbnailer.swift        # 缩略图生成 {id}_{size}.png + findMemeFile
  Image/
    GifFrameDecoder.swift    # 自研最小 GIF 解码器（LZW/interlace/色板，与 Pillow 一致）
    GifEncoder.swift         # 自研最小 GIF 编码器（median cut 256 色 + LZW，与 GifFrameDecoder 严格对应）
    MemeCopyProcessor.swift  # 复制处理：分享前按 copy_resize_mode 缩放 WebP / 转 GIF
    ImageInfo.swift          # 图片尺寸/动图判定等
  Sync/
    CloudSync.swift          # 云端同步（FTP/S3/R2/WebDAV + meme-index.json 清单 + SigV4）
    Manifest.swift           # 清单构建/解析/远端集合与顺序应用（与桌面端 manifest.py 对齐）
    LanClient.swift          # 局域网互联客户端（UDP 发现 + TCP 握手 + AES-GCM 会话）
    UpdateChecker.swift      # 版本更新检查（GitHub Releases API + 镜像回退）
  Resources/
    Info.plist               # 文件共享/打开方式/本地网络权限/ATS 全放开/Dark
OhMyMemeTests/
    DataTests.swift / ColorTests.swift / GifTests.swift / LanTests.swift / CloudSyncTests.swift
scripts/
    generate.sh / build-ipa.sh / merge-dev-to-main.bat
project.yml                  # XcodeGen 定义（min iOS 15，SDWebImage + SDWebImageWebPCoder）
```

## 存储布局（与桌面端对应）
```
Documents/                          ← 配置根（对应桌面端 %APPDATA%/OhMyMeme）
├── config.json                     ← 桌面端 %APPDATA%/OhMyMeme/config.json
└── data/                           ← localdata（对应桌面端 %LOCALAPPDATA%/OhMyMeme）
    ├── memes.db                    ← SQLite WAL
    ├── cache/                      ← 导入原图，命名 {sha256前16位}{ext}
    └── thumbnails/                 ← {meme_id}_{size}.png
```

## 关键实现细节

### 数据库（MemeDb.swift + SQLiteDatabase.swift）
- 7 表：`memes`/`tags`/`meme_tags`/`collections`/`meme_collections`/`favorites`/`recent_uses`，字段与桌面端 `database.py` 逐列一致
- `PRAGMA journal_mode=WAL`；外键依赖 ON DELETE CASCADE
- `getCollectionDepth` 按 `parent_id == 0` 判根（SQLite parent_id 无 NULL 时以 0 存储）
- 列迁移：与桌面端相同的 `ALTER TABLE ... ADD COLUMN` 容错迁移
- 单例：`AppContext.shared.db`（经 AppContext 注入，便于测试构造独立实例）
- **坑**：`SQLITE_TRANSIENT` 传参必须用 `unsafeBitCast(-1, to: sqlite3_destructor_type.self)`；所有调用点加 `lock.lock(); defer { lock.unlock() }` 防重入

### 配置（ConfigStore.swift + CryptoUtil.swift）
- `DEFAULTS` 逐字段照搬桌面端 `config.py`（含 `s3_path`、`webdav_timeout`、`sync_threads`、`lan_secret` 等）
- `SECRET_KEYS` 7 个密钥字段：`s3_access_key`/`s3_secret_key`/`r2_access_key_id`/`r2_secret_access_key`/`ftp_password`/`webdav_password`/`lan_secret`，写入前加密、读取后解密（Keychain AES-GCM）
- `load()` 读取时对密钥字段先解密；`save()` 加密副本后写盘；损坏文件回退默认值；**首次运行文件不存在时自动落盘默认配置**
- 配置变更发 `Notification.Name.configChanged`；数据变更发 `dataChanged`，主界面监听刷新

### 缓存扫描 / 导入 / 缩略图
- `CacheScanner.scan()`：遍历 cache 目录：跳过非图片扩展名、`thumbnails` 路径、与同名 `.webp` 共存的 `.gif`；**双重去重**：`getByFilename` 跳过已注册 → SHA-256 → `getByHash` 跳过重复内容
- `MemeImporter.importFile`：逐文件：查哈希去重 → 魔数识别扩展名 → 拷贝到 `cache/{hash16}{ext}` → 读尺寸 → 入库；单文件失败不影响其余（调用方 catch 后继续）
- `Thumbnailer`：命名 `{meme_id}_{size}.png`（默认 150），存在即复用；`findMemeFile` 先查 cache 根再递归；`ensureThumbnail` 生成后用 SDWebImage 降采样

### 网格加载与交互（MainViewController.swift + MemeGridCell.swift）
- 3 列网格 + `SDWebImage` 异步缩略图加载（占位图用暗色 card 色，cell 复用 tag 防错位）
- 名称取 `original_name`，为空回退文件名去扩展名
- **动图渲染**（对应桌面端 webui `auto_play_gif`）：`FileUtils.isAnimated`（GIF89a 头或 RIFF+WEBP+ANIM）且 `auto_play_gif` 为 true 时用 SDAnimatedImageView 播放原图，否则静态缩略图；解码失败回退缩略图
- 右上角「⋯」按钮 → `showMenu`（重命名/收藏/添加分组/从分组移除/删除），长按菜单已移除（与全局拖拽冲突）
- 分组胶囊（ChipCell）：收藏夹 `-2`/最近使用 `-3`/未分类 `-4` + 真实分组（含子分组展开），与桌面端 `get_collections` 一致；`show_uncategorized` 控制未分类胶囊显示
- 搜索关键词 + 分组叠加过滤；分页加载（`loadMoreIfNeeded`），下拉/滚动到底加载更多
- 点击网格 → `share(meme:)`：`MemeCopyProcessor.process` 处理 → UIActivityViewController 分享，同时 `recordUse`；分享逻辑已改 weak self + 后台处理

### 拖拽（MainViewController.swift「拖拽重排」+「拖拽发送」）
- `itemsForBeginning` 一律返回拖拽项（不受 `canReorder()` 限制，搜索/收藏/最近/未分类也能拖出到外部应用），`registerMemeContent` 注册真实图片数据
- **注册内容**：`registerDataRepresentation` 按具体 UTI（`.png/.jpeg/.gif/.webP/.bmp`）+ `UTType.image`，visibility `.all`；`loadMemeFileData` 读**原图文件**（非 MemeCopyProcessor 结果）保持声明的 UTI 与字节一致（`copy_resize_mode` 仅用于复制/分享，与桌面端拖拽行为一致）；`localObject = meme` 供网格内重排；`previewProvider` 用 `dragPreview`（优先 cell 当前图，回退缩略图）
- 拖拽开始异步 `recordUse`
- 网格内重排仍由 `canReorder()` 门控（`canHandle`/`dropSessionDidUpdate`/`performDropWith`），`persistOrder` 落库；搜索/收藏/最近/未分类禁用重排

### 版本更新（UpdateChecker.swift）
- 桌面端 `updater.py` 迁移：`parseVersion`/`compareVersions`/`fetchFirst`（并发镜像+直连，`invokeAny` 语义）；repo 为 `OhMyMeme/OhMyMeme-iOS`
- GitHub Releases API：`https://api.github.com/repos/OhMyMeme/OhMyMeme-iOS/releases/latest`，404 回退 `releases?per_page=5` 取最高版本（`pickHighestFromList`，无 `.ipa` 资产回退 release `html_url`）
- **镜像下载**：`mirrorDownloadUrl` 按 `_GH_MIRRORS`（github.dpik.top / gh.dpik.top / gh-proxy.org 等）逐个 HEAD 探测，全失败回退直连
- 设置页「检查更新」：后台线程跑，UI 主线程弹窗/Toast；iOS 无自动安装能力，引导用户去 GitHub Releases 下载 ipa

### 云端同步（CloudSync.swift）
- 对齐桌面端 `sync.py` + `manifest.py`：远端目录 `memes/` + `meme-index.json`（清单 version 3）；远端根：FTP→`ftp_path`、WebDAV→`webdav_path`、对象存储→空
- 清单字段：`memes[]`（filename/name/sha256/file_size）+ `collections[]`（嵌套树）；`Manifest.buildManifest`/`applyRemoteCollections`/`applyRemoteOrder` 与桌面端一致
- **顺序单连接执行**（单线程，不做多线程分片——iOS 端简化）；`syncTypeName` 映射 0 无 / 1 ftp / 2 s3 / 3 r2 / 4 webdav
- 后端实现（`Backend` 协议：connect/test/ensureRemoteDir/upload/download/fileExists/delete/list/close）：
  - **FTP**：POSIX socket 直写，被动模式 PASV，标准命令顺序（USER/PASS/PWD/…），控制连接超时 60s，数据连接 30s；`setControlTimeout`/`socket(addr:timeoutMs:)` 用 timeval + select 实现非阻塞超时
  - **S3/R2**：URLSession + SigV4 签名；`S3Backend(cfg:, isR2:)`，R2 endpoint=`https://{accountId}.r2.cloudflarestorage.com`，region 默认 `us-east-1`，list 用 ListObjectsV2 query + `<Key>` 解析
  - **WebDAV**：URLSession 任意方法（PROPFIND/MKCOL/PUT/GET/HEAD/DELETE），支持 http/https 与 Basic auth，`webdav_timeout` 控制超时
- **SigV4**：`CloudSync.sigV4Signature(method:path:query:host:region:amzDate:dateStamp:accessKey:secretKey:)` 静态函数（UNSIGNED-PAYLOAD，signed headers `host;x-amz-content-sha256;x-amz-date`），S3/R2 共用；测试向量用 Python botocore 交叉验证
- `push`：本地/远端按 filename+sha256 比对，相同且远端存在则跳过；`sync_delete_remote` 删远端多余；成功后合并仍保留的孤儿项重建清单上传
- `pull`：下载清单→跳过已有→下载缺失（空文件失败清理）→入库（无记录时读尺寸 `addMeme`）；`sync_remove_local` 删本地多余+库+缩略图；应用远端集合/顺序
- 公开 API：`syncTest`/`checkSyncStatus`/`push`/`pull`（返回 `SyncResult`）/`deleteAllRemote`/`cleanupRemoteOrphans`/`deleteAllLocal`；失败抛 `SyncError`
- 设置页接线：配置表单（动态按 sync_type 弹字段，secure 字段用 Keychain 加密存储）、测试连接/检查状态/上传/下载/清理孤儿/删除云端全部（危险操作弹确认）

### 局域网互联（LanClient.swift）
- **角色**：iOS 端仅客户端，连接桌面端 `lan.py` 服务（UDP 发现 + TCP 握手 + AES-GCM 会话），协议逐字节对齐
- **UDP 发现**：`discover(port:)` 广播 `{"t":"discover"}` 到 255.255.255.255:port，收集应答去重返回 `LanPeer` 列表（需 Info.plist `NSLocalNetworkUsageDescription` 本地网络权限）
- **TCP 握手**（对齐 `lan.py._handshake`）：有密钥时收 `challenge{nonce}` → 回 `proof{mac=HMAC-SHA256(secret,nonce)}` → `ok/no`；无密钥直接收 `ok`，会话密钥 32 个零字节
- **会话密钥**：PBKDF2-HMAC-SHA256（`deriveKey`，salt `ohmy-meme-lan`，100000 次，32 字节）；`hmacSha256` 十六进制
- **加密帧**：`[4B 大端长度][12B IV][AES-GCM 密文+16B tag]`；明文帧（握手期）`[4B 长度][JSON]`；`request(cmd:params:)` 用锁保证请求/响应配对
- **命令**：`ping`/`pull_manifest`/`push_manifest`/`pull_file`/`push_file`/`get_config`/`send_config`/`device_info`
- **安全校验**：`Manifest.isSafeRemoteFname` 文件名校验；单文件 ≤64MB；清单 sha256 一致性校验；pull 下载后校验可解码才落盘（杜绝孤儿文件）
- 设置页「同步电脑表情」：扫描发现 → 选 peer → 有密钥时输入密钥 → 连接（含设备确认 `device_info`，等待电脑端弹窗允许）→ 弹菜单选拉取/上传/配置同步/密钥同步（`allow_secret_config` 开启时显示，危险操作弹警告）
- **IP:端口 直连**（设置页「局域网互联」新增，对齐安卓端 `connectDirect`）：手动输入 `IP:端口`（如 `192.168.1.100:17852`）+ 可选配对密钥，`parseHostPort` 校验（端口 1...65535、IP 无空白）后构造 `LanPeer(name=ip, os="", ver="", needSecret=!secret.isEmpty)` 直接走 `connectAndSync`（复用 `LanClient.connect`，跳过 UDP 扫描），适用于同一局域网内扫描不到的电脑（手动指定端口 / 跨网段路由可达）

## 已实现 / 未实现
### 复制处理（MemeCopyProcessor.swift + GifEncoder.swift）
- 对应桌面端 `clipboard_util.py` `convert_image_mode_1/2`（`_resize_static_to_webp`/`_static_to_gif`）+ `gif_stego.py`；mode 3（隐写 GIF）依赖 XZ/LZMA2 方案，未实现
- `MemeCopyProcessor.process(meme:)`：`copy_resize_mode==0` 或动图或未超 `copy_resize_max` 返回 nil 回退原图；模式 1 缩放 WebP(q90)、模式 2 转 GIF
- 像素对齐 Pillow：`rgbaBytes` 取 CGImage RGBA，`unPremultiply` 反预乘还原真实 RGB；kind 判定 RGBA/L/RGB
- `GifEncoder.encode`：median cut 量化 ≤256 色 + GIF89a/LZW 编码；**LZW 码长升位时机 = 新增条目后 `nextCode == (1 << codeSize) + 1`**，与 `GifFrameDecoder.lzwDecode` 的 `dict.size == 1 << codeSize` 延迟升位严格对应（已 Python+Pillow 逐字节验证）
- 单测：`GifTests`（头尾字节/256 色内无损往返/确定性/超 256 色/拒绝非 GIF）；`CloudSyncTests`（SigV4 向量 + 派生密钥）；`LanTests`（HMAC/PBKDF2/帧往返/文件名安全/清单往返/连接 ping/pull/push/错误密钥）

### 已实现
- XcodeGen 工程脚手架 + 提交的 .xcodeproj + 应用图标 + Info.plist（文件共享/打开方式导入/本地网络权限）
- 暗色壳主界面（3 列网格/搜索防抖/分组胶囊含子分组展开/收藏/最近使用/未分类/分页加载/拖拽排序）
- Phase 1 数据层：SQLite 7 表/配置/Keychain 密钥加密/导入去重/缩略图/缓存扫描
- 分享/「⋯」菜单（重命名/收藏/分组/删除）/相册与文件导入/清空本地数据
- 复制处理模式 1/2（WebP 缩放 / 转 GIF，字节级对齐桌面端）
- 局域网互联客户端（UDP 发现 + HMAC-SHA256 挑战/应答 + AES-GCM 加密帧 + 设备确认 + 配置/密钥双向同步 + IP:端口 直连）
- 更新检查（GitHub Releases + 镜像回退 + 下载地址镜像探测）
- 云端同步（FTP/S3/R2/WebDAV + SigV4 + 清单 push/pull/test/status/清理孤儿/删除远端全部）
- 拖拽发送：长按拖动表情到微信/QQ 等聊天窗口直发原图（`registerDataRepresentation` 具体 UTI + `UTType.image`，全 tab 可拖，拖拽预览 + recordUse；网格内重排保留）
- 单元测试：DataTests（SHA-256/魔数/stem/动图判定/schema 与业务流/未分类计数/去重）、ColorTests、GifTests、LanTests、CloudSyncTests

### 未实现（后续待做）
- 隐写 GIF（mode 3）：依赖 XZ/LZMA2（桌面端 `lzma`，安卓端 `org.tukaani:xz`）方案，iOS 端暂无内置 LZMA 压缩 API，需引入压缩方案后对齐 `gif_stego.py` 的 FULL/差值候选逻辑