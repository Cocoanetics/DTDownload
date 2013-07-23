//
//  ViewController.m
//  ImageDownloadSample
//
//  Created by Stefan Gugarel on 7/11/13.
//  Copyright (c) 2013 Drobnik KG. All rights reserved.
//

#import "ViewController.h"

#import "DTDownloadCache.h"



@interface ViewController () <UIPickerViewDataSource, UIPickerViewDelegate>

@end

@implementation ViewController
{
	NSURL *_imageURL;
	
	BOOL _reloading;
	
	DTDownloadCacheOption _downloadCacheOption;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	// Do any additional setup after loading the view, typically from a nib.
	
	_imageURL = [NSURL URLWithString:@"http://bundles.icatalogapp.com/bundles/TestApp/cache/AJGA-Volume4-Issue11-December2012.jpg"];	
	
	_downloadOptionPickerView.dataSource = self;
	_downloadOptionPickerView.delegate = self;
	
	_activityIndicatorView.alpha = 0.0f;
	
	_reloading = NO;
}

- (void)_reloadImage
{
	if (_reloading)
	{
		return;
	}
	
	_statusLabel.text = @"loading ...";
	
	_reloading = YES;
	
	_imageView.image = nil;
	[_activityIndicatorView startAnimating];
	_activityIndicatorView.alpha = 1.0f;
	
	UIImage *image = [[DTDownloadCache sharedInstance] cachedImageForURL:_imageURL option:_downloadCacheOption completion:^(NSURL *URL, UIImage *image, NSError *error) {
		
		dispatch_async(dispatch_get_main_queue(), ^{
			
			[_activityIndicatorView stopAnimating];
			_activityIndicatorView.alpha = 0.0f;
			
			if (error)
			{
				_statusLabel.text = @"Error";
				NSString *errorMessage = [NSString stringWithFormat:@"Image cannot be loaded: %@", [error localizedDescription]];
				UIAlertView *alertView = [[UIAlertView alloc] initWithTitle:@"Error" message:errorMessage delegate:nil cancelButtonTitle:@"OK" otherButtonTitles:nil, nil];
				[alertView show];
			}
			else
			{
				_statusLabel.text = @"new loaded";
				_imageView.image = image;
			}
			
			_reloading = NO;
		});
	}];

	if (image && _downloadCacheOption == DTDownloadCacheOptionNeverLoad)
	{
		_reloading = NO;
	}

	if (image && _downloadCacheOption == DTDownloadCacheOptionLoadIfNotCached)
	{
		_reloading = NO;
	}

	if (image && _downloadCacheOption == DTDownloadCacheOptionReturnCacheAndLoadIfChanged)
	{
		_reloading = NO;
	}
	
	if (image)
	{
		_statusLabel.text = @"cached";
		_imageView.image = image;
	}
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (IBAction)reloadButtonPressed:(UIButton *)sender
{
	[self _reloadImage];
}


#pragma mark - UIPickerView Datasource

// returns the number of 'columns' to display.
- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView
{
	return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component
{
	return 4;
}

#pragma mark - UIPickerView Delegate

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component
{
	switch (row)
	{
		case DTDownloadCacheOptionNeverLoad:
			return @"Never load";
			
		case DTDownloadCacheOptionLoadIfNotCached:
			return @"Load if not cached";
			
		case DTDownloadCacheOptionReturnCacheAndLoadAlways:
			return @"Cache and load always";
			
		case DTDownloadCacheOptionReturnCacheAndLoadIfChanged:
			return @"Cache and load if changed";
	}
	
	return nil;
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component
{
	_downloadCacheOption = row;
}

@end
