#import "ZulipAppDelegate.h"
#import "ZulipAPIClient.h"
#import "UIColor+HexColor.h"
#include "ZulipAPIController.h"
#import "UIView+Layout.h"
#import "ZUser.h"
#import "RawMessage.h"
#import "UIViewController+JASidePanel.h"
#import "StreamComposeView.h"
#import "ComposeAutocompleteView.h"

#import "AFJSONRequestOperation.h"
#import "RenderedMarkdownMunger.h"
#import "BrowserViewController.h"

@interface StreamViewController ()

@property (nonatomic, retain) RawMessage *topRow;
@property (nonatomic, retain) ZulipAppDelegate *delegate;

@property (nonatomic, assign) BOOL waitingForRefresh;

@property (nonatomic, strong) UITapGestureRecognizer *dismissComposeViewGestureRecognizer;

@end

static NSString *kLoadingIndicatorDefaultMessage = @"Load older messages...";

@implementation StreamViewController

- (id)init
{
    if (self = [super init]) {
        self.title = @"Zulip";

        self.delegate = (ZulipAppDelegate *)[UIApplication sharedApplication].delegate;
        self.messages = [[NSMutableArray alloc] init];
        self.msgIds = [[NSMutableSet alloc] init];
        self.topRow = nil;
        self.waitingForRefresh = NO;

        // Configure table view and pull-to-refresh
        self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
        self.tableView.delegate = self;
        self.tableView.dataSource = self;
        self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
        self.tableView.autoresizingMask = UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleWidth;
        [self.view addSubview:self.tableView];

        self.refreshControl = [[UIRefreshControl alloc] init];
        [self.refreshControl addTarget:self action:@selector(refreshControlRefreshRequested:) forControlEvents:UIControlEventValueChanged];
        self.refreshControl.attributedTitle = [[NSAttributedString alloc] initWithString:kLoadingIndicatorDefaultMessage];
        [self.tableView addSubview:self.refreshControl];

        // Bottom padding so you can see new messages arrive.
        self.tableView.contentInset = UIEdgeInsetsMake(0.0, 0.0, 200.0, 0.0);

        // TODO re-enable registerNib:forReuseIdentifier once we work out why it is
        // breaking some message content layout on pre-1.4. It greatly speeds up scrolling
        [self.tableView registerNib:[UINib nibWithNibName:@"MessageCellView"
                                                   bundle:nil]
             forCellReuseIdentifier:[MessageCell reuseIdentifier]];

        // Always bounce vertically so that the UIRefreshController properly
        // occupies space above messages
        self.tableView.alwaysBounceVertical = YES;


        // Add inline replies
        self.autocompleteView = [[ComposeAutocompleteView alloc] initWithFrame:self.view.bounds];
        [self.view addSubview:self.autocompleteView];

        self.composeView = [[StreamComposeView alloc] initWithAutocompleteView:self.autocompleteView];
        [self.composeView moveToPoint:CGPointMake(0, self.view.bottom - self.composeView.height)];
        self.composeView.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleWidth;
        [self.view addSubview:self.composeView];
        

        // Listen to long polling messages
        [[NSNotificationCenter defaultCenter] addObserverForName:kLongPollMessageNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
                                                          NSArray *messages = [[note userInfo] objectForKey:kLongPollMessageData];
                                                          [self handleLongPollMessages:messages];
                                                      }];

        // Reset on logout
        [[NSNotificationCenter defaultCenter] addObserverForName:kLogoutNotification
                                                          object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(NSNotification *note) {
                                                          [self clearMessages];
                                                      }];

        // KVO watch for resume from background
        [[ZulipAPIController sharedInstance] addObserver:self
                                              forKeyPath:@"backgrounded"
                                                 options:(NSKeyValueObservingOptionNew |
                                                          NSKeyValueObservingOptionOld)
                                                 context:nil];


        UIBarButtonItem *rightButton = [[UIBarButtonItem alloc] initWithImage:[UIImage imageNamed:@"user-toolbar"] style:UIBarButtonItemStylePlain target:self action:@selector(didTapUsersButton)];
        self.navigationItem.rightBarButtonItem = rightButton;

        
        if ([self.tableView respondsToSelector:@selector(setKeyboardDismissMode:)]) {
            self.tableView.keyboardDismissMode =UIScrollViewKeyboardDismissModeOnDrag;
        } else {
            self.dismissComposeViewGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didDismissComposeView)];
        }
    }
    return self;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];

    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation {
    [self.composeView resizeTo:CGSizeMake(self.view.width, self.composeView.height)];
    [self.autocompleteView resizeTo:CGSizeMake(self.view.width, self.autocompleteView.height)];
}

- (void)clearMessages
{
    [self.messages removeAllObjects];
    [self.msgIds removeAllObjects];
    self.topRow = nil;
    [self.tableView reloadData];
}

- (BOOL)shouldAutorotateToInterfaceOrientation:(UIInterfaceOrientation)interfaceOrientation
{
    // Return YES for supported orientations
    return (interfaceOrientation == UIInterfaceOrientationPortrait);
}

- (void)didReceiveMemoryWarning
{
    // Releases the view if it doesn't have a superview.
    [super didReceiveMemoryWarning];

    // Release any cached data, images, etc. that aren't in use.
}

- (void)viewDidUnload
{
    [super viewDidUnload];
}

- (void)initialPopulate
{}

- (void)resumePopulate
{}

- (void)refreshControlRefreshRequested:(UIRefreshControl *)refresh
{
    refresh.attributedTitle = [[NSAttributedString alloc] initWithString:@"Fetching older messages..."];

    self.waitingForRefresh = YES;
}

#pragma mark - UIScrollView

// We want to load messages **after** the scroll & deceleration is finished.
// Unfortunately, scrollViewDidFinishDecelerating doesn't work, so we use
// this trick from facebook's Three20 library.
-(void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    [self performSelector:@selector(scrollViewDidEndScrollingAnimation:) withObject:nil afterDelay:0.3];
}


-(void)scrollViewWillEndDragging:(UIScrollView *)scrollView withVelocity:(CGPoint)velocity targetContentOffset:(inout CGPoint *)targetContentOffset
{
//    NSLog(@"WIll end at %f, height is %f", targetContentOffset->y, );
    CGFloat bottom = self.tableView.contentSize.height - self.tableView.height;

    CGFloat bottomPrefetchPadding = 100;
    if (targetContentOffset->y + bottomPrefetchPadding >= bottom) {
        [self loadNewerMessages];
    }
}

-(void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];
    if (self.waitingForRefresh) {
        self.waitingForRefresh = NO;

        if ([self.messages count] > 0) {
            self.topRow = [self.messages objectAtIndex:0];
            [[ZulipAPIController sharedInstance] loadMessagesAroundAnchor:[self.topRow.messageID longValue] - 1
                                                                   before:15
                                                                    after:0
                                                            withOperators:self.operators
                                                          completionBlock:^(NSArray *messages) {
                  [self.refreshControl endRefreshing];
                  self.refreshControl.attributedTitle = [[NSAttributedString alloc] initWithString:kLoadingIndicatorDefaultMessage];

                  [self loadMessages: messages];

              }];
        }

        return;
    }

    CGFloat bottom = self.tableView.contentSize.height - self.tableView.height;

    CGFloat bottomPrefetchPadding = 100;
    if (self.tableView.contentOffset.y + bottomPrefetchPadding >= bottom) {
        [self loadNewerMessages];
    }
}

- (void)loadNewerMessages
{
    RawMessage *last = [self.messages lastObject];
    if (last && [last.messageID longValue] < [ZulipAPIController sharedInstance].maxServerMessageId) {
        NSLog(@"Scrolling to bottom and fetching more messages");
        [[ZulipAPIController sharedInstance] loadMessagesAroundAnchor:[last.messageID longValue]
                                                               before:0
                                                                after:40
                                                        withOperators:self.operators
                                                      completionBlock:^(NSArray *newerMessages) {
              NSLog(@"Initially loaded forward %i messages!", [newerMessages count]);
              [self loadMessages:newerMessages];
          }];
    }
}
#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

-(NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section
{
    return [self.messages count];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath
{
    [(MessageCell *)cell willBeDisplayed];
}

- (RawMessage *)messageAtIndexPath:(NSIndexPath *)indexPath
{
    return [self.messages objectAtIndex:indexPath.row];
}

-(UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath
{
    if ([self.messages count] == 0) {
        return nil;
    }

    RawMessage *message = [self messageAtIndexPath:indexPath];

    MessageCell *cell = (MessageCell *)[self.tableView dequeueReusableCellWithIdentifier:[MessageCell reuseIdentifier]];
    if (cell == nil) {
        NSArray *objects = [[NSBundle mainBundle] loadNibNamed:@"MessageCellView" owner:self options:nil];
        cell = (MessageCell *)[objects objectAtIndex:0];
    }

    [cell setMessage:message];
    cell.delegate = self;

    return cell;
}

- (CGFloat) tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    RawMessage * message = [self messageAtIndexPath:indexPath];
    return [MessageCell heightForCellWithMessage:message];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath
{
    RawMessage *message = [self messageAtIndexPath:indexPath];
    ComposeViewController *composeView = [[ComposeViewController alloc] initWithReplyTo:message];

    composeView.type = message.type;
    [[self navigationController] pushViewController:composeView animated:YES];
}

- (void)openLink:(NSURL *)URL
{
    BrowserViewController* webView = [[BrowserViewController alloc] initWithUrls:URL];
    [[self navigationController] pushViewController:webView animated:YES];
}

#pragma mark - StreamViewController

-(void)didTapUsersButton {
    [self.findSidePanelController showRightPanelAnimated:YES];
}

-(int)rowWithId:(int)messageId
{
    NSUInteger i = 0;
    for (i = 0; i < [self.messages count]; i++) {
        RawMessage *message = [self messageAtIndexPath:[NSIndexPath indexPathForItem:i inSection:0]];
        if ([message.messageID intValue] == messageId) {
            return i;
        }
    }
    return -1;
}

-(void)loadMessages:(NSArray *)messages
{
    BOOL insertingAtTop = NO;
    CGPoint offset;
    CGFloat height = self.tableView.contentSize.height;

    if ([messages count] > 0) {
        RawMessage *last = [messages lastObject];

//        NSLog(@"Adding %i backlog with last new message; %@ < %@", [messages count], last.messageID, self.topRow.messageID);
        if (last && ([last.messageID longValue] < [self.topRow.messageID longValue])) {
            insertingAtTop = YES;
            [UIView setAnimationsEnabled:NO];
            offset = [self.tableView contentOffset];
        }
    }

    // this block influenced by: http://stackoverflow.com/questions/8180115/nsmutablearray-add-object-with-order
    // we want to do an in-order insert so that whether doing the initial backfill or inserting historical messages as requested,
    // this method doesn't require special booleans or state.
    for (RawMessage *message in messages) {
        [RenderedMarkdownMunger mungeThis:message];

        if ([self.msgIds containsObject:message.messageID])
            continue;
        else
            [self.msgIds addObject:message.messageID];

        NSUInteger insertionIndex = [self.messages indexOfObject:message
                                                   inSortedRange:(NSRange){0, [self.messages count]}
                                                         options:NSBinarySearchingInsertionIndex
                                                 usingComparator:^(id left, id right) {
           RawMessage *rLeft = (RawMessage *)left;
           RawMessage *rRight = (RawMessage *)right;
           return [rLeft.messageID compare:rRight.messageID];
        }];

        [self.messages insertObject:message atIndex:insertionIndex];

        [message registerForChanges:^(RawMessage *rawMsg) {
            [self rawMessageDidChange:rawMsg];
        }];
    }

    [self.tableView reloadData];

    if (insertingAtTop) {
        // If inserting at top, calculate the pixels height that was inserted, and scroll to the same position
        offset.y = self.tableView.contentSize.height - height;
        [self.tableView setContentOffset:offset];
        [UIView setAnimationsEnabled:YES];

        // Maintain the same scroll position, and replace the "Loading more messages"
        // banner with the newly loaded messages
        CGFloat peek_height =  self.refreshControl.height;
        CGRect peek = CGRectMake(0, offset.y - peek_height, self.tableView.bounds.size.width, peek_height);
        [self.tableView scrollRectToVisible:peek animated:NO];
    }
}

- (void)handleLongPollMessages:(NSArray *)messages
{
    NSMutableArray *accepted = [[NSMutableArray alloc] init];
    for (RawMessage *msg in messages) {
        if (self.operators && [self.operators acceptsMessage:msg])
            [accepted addObject:msg];
    }
    [self loadMessages:accepted];
}

#pragma mark - Message Change Observing

- (void)rawMessageDidChange:(RawMessage *)message
{
    NSUInteger index = [self.messages indexOfObject:message];
    if (index != NSNotFound) {
        NSIndexPath *path = [NSIndexPath indexPathForRow:index inSection:0];
        MessageCell *cell = (MessageCell *)[self.tableView cellForRowAtIndexPath:path];

        [cell setMessage:message];
    }
}

#pragma mark - NSKeyValueObserving

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ([keyPath isEqualToString:@"backgrounded"]) {
        BOOL old = [[change objectForKey:NSKeyValueChangeOldKey] boolValue];
        BOOL new = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];

        if (old && !new) {
            [self resumePopulate];
        }
    }
}

#pragma mark - MessageComposing protocol
- (void)showComposeViewForUser:(ZUser *)user {
    [self.composeView showComposeViewForUser:user];
}

#pragma mark - Keyboard show/hide
- (void)keyboardWillHide:(NSNotification *)notification {
    if (self.dismissComposeViewGestureRecognizer) {
        [self.tableView removeGestureRecognizer:self.dismissComposeViewGestureRecognizer];
    }

    self.autocompleteView.hidden = YES;
    [self.composeView hideSubjectBar];
    [self moveComposeViewForNotification:notification];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    if (self.dismissComposeViewGestureRecognizer) {
        [self.tableView addGestureRecognizer:self.dismissComposeViewGestureRecognizer];
    }

    [self.composeView showSubjectBar];
    [self moveComposeViewForNotification:notification];
    [self resizeAutocompleteViewForNotification:notification];
}

- (void)moveComposeViewForNotification:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    NSTimeInterval duration = [[userInfo objectForKey:UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = [[userInfo objectForKey:UIKeyboardAnimationCurveUserInfoKey] intValue];

    CGRect keyboardFrame = [[userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardFrameForTextField = [self.composeView.superview convertRect:keyboardFrame fromView:nil];

    [UIView animateWithDuration:duration delay:0 options:UIViewAnimationOptionBeginFromCurrentState | curve animations:^{
        CGFloat newTop = keyboardFrameForTextField.origin.y - self.composeView.height;
        [self.composeView moveToPoint:CGPointMake(self.composeView.left, newTop)];
    } completion:nil];

    UIEdgeInsets tableViewInset = self.tableView.contentInset;
    tableViewInset.bottom = keyboardFrame.size.height + self.composeView.visibleHeight;
    self.tableView.contentInset = tableViewInset;
}

- (void)resizeAutocompleteViewForNotification:(NSNotification *)notification {
    NSDictionary *userInfo = notification.userInfo;
    CGRect keyboardFrame = [[userInfo objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect keyboardFrameForTextField = [self.composeView.superview convertRect:keyboardFrame fromView:nil];
    CGFloat originY = 0;

    if ([self respondsToSelector:@selector(topLayoutGuide)]) {
        originY = self.topLayoutGuide.length;
    }

    CGFloat height = self.view.height - originY - keyboardFrameForTextField.size.height - self.composeView.visibleHeight;

    [self.autocompleteView moveToPoint:CGPointMake(0, originY)];
    [self.autocompleteView resizeTo:CGSizeMake(self.view.width, height)];
}

- (void)didDismissComposeView {
    if (self.composeView.isFirstResponder) {
        [self.composeView resignFirstResponder];
    }
}

@end
