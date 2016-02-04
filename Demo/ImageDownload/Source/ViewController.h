//
//  ViewController.h
//  ImageDownloadSample
//
//  Created by Stefan Gugarel on 7/11/13.
//  Copyright (c) 2013 Drobnik KG. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface ViewController : UIViewController

@property (weak, nonatomic) IBOutlet UIImageView *imageView;

@property (weak, nonatomic) IBOutlet UILabel *statusLabel;

@property (weak, nonatomic) IBOutlet UIPickerView *downloadOptionPickerView;

@property (weak, nonatomic) IBOutlet UIProgressView *downloadProgress;


- (IBAction)reloadButtonPressed:(UIButton *)sender;

@end
