#import "LoginViewController.h"
#import "ZulipAppDelegate.h"
#import "ZulipAPIController.h"
#import "ZulipAPIClient.h"
#import "GoogleOAuthManager.h"

#import "KeychainItemWrapper.h"

#import "BrowserViewController.h"
#import "UIView+Layout.h"
#import "MBProgressHUD.h"
#import <SafariServices/SafariServices.h>


@interface LoginViewController () <SFSafariViewControllerDelegate>

@end

@interface LoginViewController ()
@property (weak, nonatomic) IBOutlet UIScrollView *scrollView;
@property (strong, nonatomic) ZulipAppDelegate *appDelegate;
@property (strong, nonatomic) GoogleOAuthManager *googleManager;
@property (strong, nonatomic) SFSafariViewController *sfvc;
@end

@implementation LoginViewController

- (id)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil
{
    if (self = [super initWithNibName:nibNameOrNil bundle:nibBundleOrNil]) {
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserverForName:kSchemaLoginNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
                                                          [self close];
                                                      }];
    }
    return self;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self.navigationController setNavigationBarHidden:YES animated:YES];

    self.password.secureTextEntry = YES;
    self.appDelegate = (ZulipAppDelegate *)[[UIApplication sharedApplication] delegate];

    KeychainItemWrapper *keychainItem = [[KeychainItemWrapper alloc] initWithIdentifier:@"ZulipLogin" accessGroup:nil];
    NSString *domain = [keychainItem objectForKey:(__bridge id)kSecAttrLabel];

    int domainlen = [domain length];

    if (!domain || domainlen == 0){
        self.serverDomain.text = @"zulip.com";
    } else {
        self.serverDomain.text = domain;
    }

    self.entryFields = [[NSMutableArray alloc] init];
    NSInteger tag = 1;
    UIView *aView;
    while ((aView = [self.view viewWithTag:tag])) {
        if (aView && [[aView class] isSubclassOfClass:[UIResponder class]]) {
            [self.entryFields addObject:aView];
        }
        tag++;
    }

    // Focus on email field.
    [self.email becomeFirstResponder];
}

- (void)willRotateToInterfaceOrientation:(UIInterfaceOrientation)toInterfaceOrientation duration:(NSTimeInterval)duration {
    self.scrollView.frame = self.view.bounds;
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.navigationController setNavigationBarHidden:NO animated:YES];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
}

#pragma mark - SFSafariViewController delegate methods
-(void)safariViewController:(SFSafariViewController *)controller didCompleteInitialLoad:(BOOL)didLoadSuccessfully {
    // Load finished
}

-(void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    [self dismissViewControllerAnimated:YES completion:nil];
}

-(void) close {
    NSLog(@"Trying to close safari");

    [self.sfvc dismissViewControllerAnimated:NO completion:nil];

    [[ZulipAPIController sharedInstance] loginWithAPI:^(bool loggedIn) {
        if (loggedIn) {
            NSLog(@"Login via API successful");
            [self.appDelegate dismissLoginScreen];
        } else {
            NSLog(@"Failed to login!");
            [self.email resignFirstResponder];
            [self.password resignFirstResponder];
            [self.appDelegate showErrorScreen:@"Unable to login. Please try again."];
        }
    }];
}

- (IBAction)didTapSafariButton:(id)sender {
    NSLog(@"Trying to open safari");
    NSLog(@"%@", self.serverDomain.text);

    NSString* loginUrl = [NSString stringWithFormat:@"http://%@/accounts/login/mobile_redirect/", self.serverDomain.text];

    self.sfvc = [[SFSafariViewController alloc]initWithURL:[NSURL URLWithString:loginUrl] entersReaderIfAvailable:NO];
    self.sfvc.delegate = self;
    [self presentViewController:self.sfvc animated:NO completion:nil];

}

#pragma mark - Event handlers
- (IBAction)didTapGoogleButton:(id)sender {
    self.googleManager = [[GoogleOAuthManager alloc] init];
    UIViewController *loginController = [self.googleManager showAuthScreenWithSuccess:^(NSDictionary *result) {
        [self.navigationController popViewControllerAnimated:NO];
        [self loginToDomain:self.serverDomain.text WithUsername:@"google-oauth2-token" password:result[@"id_token"]];
    } failure:^(NSError *error) {
        [self.navigationController popViewControllerAnimated:YES];
        [self.appDelegate showErrorScreen:@"Unable to login with Google. Please try again."];
    }];

    [self.email resignFirstResponder];
    [self.password resignFirstResponder];
    [self.navigationController pushViewController:loginController animated:YES];
}

- (void)loginToDomain:(NSString *)domain WithUsername:(NSString *)email password:(NSString *)password {
    [[ZulipAPIController sharedInstance] logout];
    [[ZulipAPIController sharedInstance] login:domain email:email password:password result:^(bool loggedIn) {
        if (loggedIn) {
            [self.appDelegate dismissLoginScreen];
        } else {
            NSLog(@"Failed to login!");
            [self.email resignFirstResponder];
            [self.password resignFirstResponder];
            [self.appDelegate showErrorScreen:@"Unable to login. Please try again."];
        }
    }];
}

- (IBAction) login: (id) sender {
    NSString *trimmedEmail = [self.email.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    [self loginToDomain:self.serverDomain.text WithUsername:trimmedEmail password:self.password.text];
}

- (IBAction) about:(id)sender
{
    [self.appDelegate showAboutScreen];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
	// Find the next entry field
	for (UIView *view in self.entryFields) {
		if (view.tag == (textField.tag + 1)) {
			[view becomeFirstResponder];
			break;
		}
	}

    if (textField == self.password) {
        [textField resignFirstResponder];
        [self login:nil];
    }

	return NO;
}

#pragma mark - Keyboard functions
- (void)keyboardWillShow:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    CGRect keyboardFrame = [[userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardFrameForTextField = [self.view convertRect:keyboardFrame fromView:nil];

    NSLog(@"%f, %f", keyboardFrameForTextField.size.height, self.view.height);
    self.scrollView.contentSize = CGSizeMake(self.view.width, self.view.height);
    [self.scrollView resizeTo:CGSizeMake(self.view.width, self.view.height - keyboardFrameForTextField.size.height)];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    [self.scrollView resizeTo:self.view.size];
}

@end
