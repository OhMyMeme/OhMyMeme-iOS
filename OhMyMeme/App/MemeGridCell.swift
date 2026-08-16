import UIKit
import SDWebImage

final class MemeGridCell: UICollectionViewCell {
    static let reuseId = "MemeGridCell"

    private let imageView = UIImageView()
    private let animatedView = SDAnimatedImageView()
    private let nameLabel = UILabel()
    private let badgeLabel = UILabel()
    private let menuButton = UIButton(type: .system)

    var menuHandler: (() -> Void)?

    /// 当前显示的图片（拖拽悬浮预览用）
    var currentImage: UIImage? {
        animatedView.isHidden ? imageView.image : animatedView.image
    }

    private static let placeholder: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 150, height: 150)).image { ctx in
            UIColor(hex: 0x1E1E22).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 150, height: 150))
        }
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(hex: 0x1E1E22)
        layer.cornerRadius = 8
        clipsToBounds = true

        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(imageView)

        animatedView.contentMode = .scaleAspectFill
        animatedView.clipsToBounds = true
        animatedView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(animatedView)

        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = UIColor(hex: 0x9CA3AF)
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(nameLabel)

        badgeLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.textAlignment = .center
        badgeLabel.layer.cornerRadius = 3
        badgeLabel.clipsToBounds = true
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badgeLabel)

        menuButton.setTitle("⋯", for: .normal)
        menuButton.setTitleColor(UIColor(hex: 0x9CA3AF), for: .normal)
        menuButton.titleLabel?.font = .systemFont(ofSize: 15, weight: .bold)
        menuButton.backgroundColor = UIColor(hex: 0x0D0D0F).withAlphaComponent(0.55)
        menuButton.layer.cornerRadius = 10
        menuButton.clipsToBounds = true
        menuButton.translatesAutoresizingMaskIntoConstraints = false
        menuButton.addTarget(self, action: #selector(menuTapped), for: .touchUpInside)
        contentView.addSubview(menuButton)

        NSLayoutConstraint.activate([
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),

            animatedView.topAnchor.constraint(equalTo: contentView.topAnchor),
            animatedView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            animatedView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            animatedView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -22),

            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6),
            nameLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),

            badgeLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            badgeLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            badgeLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 26),
            badgeLabel.heightAnchor.constraint(equalToConstant: 14),

            menuButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            menuButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2),
            menuButton.widthAnchor.constraint(equalToConstant: 22),
            menuButton.heightAnchor.constraint(equalToConstant: 22)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        imageView.sd_cancelCurrentImageLoad()
        animatedView.sd_cancelCurrentImageLoad()
        imageView.image = nil
        animatedView.image = nil
        badgeLabel.isHidden = true
    }

    func configure(meme: Meme, isAnimated: Bool, autoPlay: Bool) {
        nameLabel.text = meme.displayName

        if meme.fromStego == 1 {
            badgeLabel.isHidden = false
            badgeLabel.text = "隐写"
            badgeLabel.backgroundColor = UIColor(hex: 0xF59E0B)
        } else if isAnimated {
            badgeLabel.isHidden = false
            badgeLabel.text = FileUtils.ext(fromName: meme.filename) == ".gif" ? "GIF" : "WebP"
            badgeLabel.backgroundColor = UIColor(hex: 0x3B82F6)
        } else {
            badgeLabel.isHidden = true
        }

        let src = Thumbnailer.cacheFileURL(meme.filename)
        let exists = FileManager.default.fileExists(atPath: src.path)
        if isAnimated && autoPlay && exists {
            animatedView.isHidden = false
            imageView.isHidden = true
            animatedView.sd_setImage(with: src, placeholderImage: Self.placeholder)
        } else {
            animatedView.isHidden = true
            imageView.isHidden = false
            if exists {
                let context: [SDWebImageContextOption: Any] = [
                    .imageThumbnailPixelSize: CGSize(width: 320, height: 320)
                ]
                imageView.sd_setImage(with: src, placeholderImage: Self.placeholder, options: [], context: context)
            }
        }
    }

    @objc private func menuTapped() {
        menuHandler?()
    }
}