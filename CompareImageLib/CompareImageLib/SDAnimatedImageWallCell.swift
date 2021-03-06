//
//  SDAnimatedImageWallCell.swift
//  CompareImageLib
//
//  Created by Kaibo Lu on 3/15/19.
//  Copyright © 2019 Kaibo Lu. All rights reserved.
//

import UIKit
import SDWebImage

class SDAnimatedImageWallCell: UICollectionViewCell {
    private var imageView: FLAnimatedImageView!
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        imageView = FLAnimatedImageView(frame: CGRect(origin: .zero, size: frame.size))
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        contentView.addSubview(imageView)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func set(url: URL) {
        let placeholder = UIImage(named: "placeholder")
        imageView.sd_setImage(with: url, placeholderImage: placeholder, options: [], completed: nil)
    }
}
