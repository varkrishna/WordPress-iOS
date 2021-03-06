import Foundation
import CocoaLumberjack
import WordPressShared
import wpxmlrpc

// FIXME: comparison operators with optionals were removed from the Swift Standard Libary.
// Consider refactoring the code to use the non-optional operators.
fileprivate func < <T: Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l < r
  case (nil, _?):
    return true
  default:
    return false
  }
}

// FIXME: comparison operators with optionals were removed from the Swift Standard Libary.
// Consider refactoring the code to use the non-optional operators.
fileprivate func > <T: Comparable>(lhs: T?, rhs: T?) -> Bool {
  switch (lhs, rhs) {
  case let (l?, r?):
    return l > r
  default:
    return rhs < lhs
  }
}


class AbstractPostListViewController: UIViewController, WPContentSyncHelperDelegate, WPNoResultsViewDelegate, UISearchControllerDelegate, UISearchResultsUpdating, WPTableViewHandlerDelegate {

    typealias WPNoResultsView = WordPressShared.WPNoResultsView

    fileprivate static let postsControllerRefreshInterval = TimeInterval(300)
    fileprivate static let HTTPErrorCodeForbidden = Int(403)
    fileprivate static let postsFetchRequestBatchSize = Int(10)
    fileprivate static let postsLoadMoreThreshold = Int(4)
    fileprivate static let preferredFiltersPopoverContentSize = CGSize(width: 320.0, height: 220.0)

    fileprivate static let defaultHeightForFooterView = CGFloat(44.0)

    fileprivate let abstractPostWindowlessCellIdenfitier = "AbstractPostWindowlessCellIdenfitier"

    var blog: Blog!

    /// This closure will be executed whenever the noResultsView must be visually refreshed.  It's up
    /// to the subclass to define this property.
    ///
    var refreshNoResultsView: ((WPNoResultsView) -> ())!
    var tableViewController: UITableViewController!
    var reloadTableViewBeforeAppearing = false

    var tableView: UITableView {
        get {
            return self.tableViewController.tableView
        }
    }

    var refreshControl: UIRefreshControl? {
        get {
            return self.tableViewController.refreshControl
        }
    }

    lazy var tableViewHandler: WPTableViewHandler = {
        let tableViewHandler = WPTableViewHandler(tableView: self.tableView)

        tableViewHandler.cacheRowHeights = false
        tableViewHandler.delegate = self
        tableViewHandler.updateRowAnimation = .none

        return tableViewHandler
    }()

    lazy var estimatedHeightsCache: NSCache = { () -> NSCache<AnyObject, AnyObject> in
        let estimatedHeightsCache = NSCache<AnyObject, AnyObject>()
        return estimatedHeightsCache
    }()

    lazy var syncHelper: WPContentSyncHelper = {
        let syncHelper = WPContentSyncHelper()

        syncHelper.delegate = self

        return syncHelper
    }()

    lazy var searchHelper: WPContentSearchHelper = {
        let searchHelper = WPContentSearchHelper()
        return searchHelper
    }()

    lazy var noResultsView: WPNoResultsView = {
        let noResultsView = WPNoResultsView()
        noResultsView.delegate = self

        return noResultsView
    }()

    lazy var filterSettings: PostListFilterSettings = {
        return PostListFilterSettings(blog: self.blog, postType: self.postTypeToSync())
    }()


    var postListFooterView: PostListFooterView!

    @IBOutlet var filterButton: NavBarTitleDropdownButton!
    @IBOutlet var rightBarButtonView: UIView!
    @IBOutlet var addButton: UIButton!

    var searchController: UISearchController!
    var recentlyTrashedPostObjectIDs = [NSManagedObjectID]() // IDs of trashed posts. Cleared on refresh or when filter changes.

    fileprivate var searchesSyncing = 0

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        refreshControl?.addTarget(self, action: #selector(refresh(_:)), for: .valueChanged)

        configureTableView()
        configureFooterView()
        configureWindowlessCell()
        configureNavbar()
        configureSearchController()
        configureSearchHelper()
        configureAuthorFilter()

        WPStyleGuide.configureColors(for: view, andTableView: tableView)
        tableView.reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        if reloadTableViewBeforeAppearing {
            reloadTableViewBeforeAppearing = false
            tableView.reloadData()
        }

        refreshResults()
        registerForKeyboardNotifications()
    }

    fileprivate func registerForKeyboardNotifications() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidShow(_:)), name: NSNotification.Name.UIKeyboardDidShow, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardDidHide(_:)), name: NSNotification.Name.UIKeyboardDidHide, object: nil)
    }

    fileprivate func unregisterForKeyboardNotifications() {
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIKeyboardDidShow, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIKeyboardDidHide, object: nil)
    }

    @objc fileprivate func keyboardDidShow(_ notification: Foundation.Notification) {
        let keyboardFrame = localKeyboardFrameFromNotification(notification)
        let keyboardHeight = tableView.frame.maxY - keyboardFrame.origin.y

        tableView.contentInset.top = topLayoutGuide.length
        tableView.contentInset.bottom = keyboardHeight
        tableView.scrollIndicatorInsets.top = searchBarHeight
        tableView.scrollIndicatorInsets.bottom = keyboardHeight
    }

    @objc fileprivate func keyboardDidHide(_ notification: Foundation.Notification) {
        tableView.contentInset.top = topLayoutGuide.length
        tableView.contentInset.bottom = 0
        tableView.scrollIndicatorInsets.top = searchController.isActive ? searchBarHeight : topLayoutGuide.length
        tableView.scrollIndicatorInsets.bottom = 0
    }

    fileprivate var searchBarHeight: CGFloat {
        return searchController.searchBar.bounds.height + topLayoutGuide.length
    }

    fileprivate func localKeyboardFrameFromNotification(_ notification: Foundation.Notification) -> CGRect {
        guard let keyboardFrame = (notification.userInfo?[UIKeyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else {
                return .zero
        }

        // Convert the frame from window coordinates
        return view.convert(keyboardFrame, from: nil)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        if !searchController.isActive {
            configureInitialScrollInsets()
        }

        automaticallySyncIfAppropriate()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        if searchController.isActive {
            searchController.isActive = false
        }

        NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
        unregisterForKeyboardNotifications()
    }

    // MARK: - Configuration

    func heightForFooterView() -> CGFloat {
        return type(of: self).defaultHeightForFooterView
    }

    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }

    func configureNavbar() {
        // IMPORTANT: this code makes sure that the back button in WPPostViewController doesn't show
        // this VC's title.
        //
        let backButton = UIBarButtonItem(title: "", style: .plain, target: nil, action: nil)
        navigationItem.backBarButtonItem = backButton

        let rightBarButtonItem = UIBarButtonItem(customView: rightBarButtonView)
        WPStyleGuide.setRightBarButtonItemWithCorrectSpacing(rightBarButtonItem, for: navigationItem)

        navigationItem.titleView = filterButton
        updateFilterTitle()
    }

    func configureTableView() {
        assert(false, "You should implement this method in the subclass")
    }

    func configureFooterView() {

        let mainBundle = Bundle.main

        guard let footerView = mainBundle.loadNibNamed("PostListFooterView", owner: nil, options: nil)![0] as? PostListFooterView else {
            preconditionFailure("Could not load the footer view from the nib file.")
        }

        postListFooterView = footerView
        postListFooterView.showSpinner(false)

        var frame = postListFooterView.frame
        frame.size.height = heightForFooterView()

        postListFooterView.frame = frame
        tableView.tableFooterView = postListFooterView
    }

    func configureWindowlessCell() {
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: abstractPostWindowlessCellIdenfitier)
    }

    fileprivate func refreshResults() {
        guard isViewLoaded == true else {
            return
        }

        if tableViewHandler.resultsController.fetchedObjects?.count > 0 {
            hideNoResultsView()
        } else {
            showNoResultsView()
        }
    }

    func configureAuthorFilter() {
        fatalError("You should implement this method in the subclass")
    }

    /// Subclasses should override this method (and call super) to insert the
    /// search controller's search bar into the view hierarchy
    func configureSearchController() {
        // Required for insets to work out correctly when the search bar becomes active
        extendedLayoutIncludesOpaqueBars = true
        definesPresentationContext = true

        searchController = UISearchController(searchResultsController: nil)
        searchController.dimsBackgroundDuringPresentation = false

        searchController.delegate = self
        searchController.searchResultsUpdater = self

        WPStyleGuide.configureSearchBar(searchController.searchBar)

        searchController.searchBar.autocorrectionType = .default
    }

    fileprivate func configureInitialScrollInsets() {
        tableView.scrollIndicatorInsets.top = topLayoutGuide.length
    }

    func configureSearchHelper() {
        searchHelper.resetConfiguration()
        searchHelper.configureImmediateSearch({ [weak self] in
            self?.updateForLocalPostsMatchingSearchText()
        })
        searchHelper.configureDeferredSearch({ [weak self] in
            self?.syncPostsMatchingSearchText()
        })
    }

    func propertiesForAnalytics() -> [String: AnyObject] {
        var properties = [String: AnyObject]()

        properties["type"] = postTypeToSync().rawValue as AnyObject?
        properties["filter"] = filterSettings.currentPostListFilter().title as AnyObject?

        if let dotComID = blog.dotComID {
            properties[WPAppAnalyticsKeyBlogID] = dotComID
        }

        return properties
    }

    // MARK: - GUI: No results view logic

    fileprivate func hideNoResultsView() {
        postListFooterView.isHidden = false
        noResultsView.removeFromSuperview()
    }

    fileprivate func showNoResultsView() {
        precondition(refreshNoResultsView != nil)

        postListFooterView.isHidden = true
        refreshNoResultsView(noResultsView)

        // Only add and animate no results view if it isn't already
        // in the table view
        if noResultsView.isDescendant(of: tableView) == false {
            tableView.addSubview(withFadeAnimation: noResultsView)
            noResultsView.translatesAutoresizingMaskIntoConstraints = false
            tableView.pinSubviewAtCenter(noResultsView)
        }

        tableView.sendSubview(toBack: noResultsView)
    }

    // MARK: - TableView Helpers

    func dequeCellForWindowlessLoadingIfNeeded(_ tableView: UITableView) -> UITableViewCell? {
        // As also seen in ReaderStreamViewController:
        // We want to avoid dequeuing card cells when we're not present in a window, on the iPad.
        // Doing so can create a situation where cells are not updated with the correct NSTraitCollection.
        // The result is the cells do not show the correct layouts relative to superview margins.
        // HACK: kurzee, 2016-07-12
        // Use a generic cell in this situation and reload the table view once its back in a window.
        if (tableView.window == nil) {
            reloadTableViewBeforeAppearing = true
            return tableView.dequeueReusableCell(withIdentifier: abstractPostWindowlessCellIdenfitier)
        }
        return nil
    }

    // MARK: - TableViewHandler Delegate Methods

    func entityName() -> String {
        fatalError("You should implement this method in the subclass")
    }

    func managedObjectContext() -> NSManagedObjectContext {
        return ContextManager.sharedInstance().mainContext
    }

    func fetchRequest() -> NSFetchRequest<NSFetchRequestResult> {
        let fetchRequest = NSFetchRequest<NSFetchRequestResult>(entityName: entityName())

        fetchRequest.predicate = predicateForFetchRequest()
        fetchRequest.sortDescriptors = sortDescriptorsForFetchRequest()
        fetchRequest.fetchBatchSize = type(of: self).postsFetchRequestBatchSize
        fetchRequest.fetchLimit = Int(numberOfPostsPerSync())

        return fetchRequest
    }

    func sortDescriptorsForFetchRequest() -> [NSSortDescriptor] {
        return filterSettings.currentPostListFilter().sortDescriptors
    }

    func updateAndPerformFetchRequest() {
        assert(Thread.isMainThread, "AbstractPostListViewController Error: NSFetchedResultsController accessed in BG")

        var predicate = predicateForFetchRequest()
        let sortDescriptors = sortDescriptorsForFetchRequest()
        let fetchRequest = tableViewHandler.resultsController.fetchRequest

        // Set the predicate based on filtering by the oldestPostDate and not searching.
        let filter = filterSettings.currentPostListFilter()

        if let oldestPostDate = filter.oldestPostDate, !isSearching() {

            // Filter posts by any posts newer than the filter's oldestPostDate.
            // Also include any posts that don't have a date set, such as local posts created without a connection.
            let datePredicate = NSPredicate(format: "(date_created_gmt = NULL) OR (date_created_gmt >= %@)", oldestPostDate as CVarArg)

            predicate = NSCompoundPredicate.init(andPredicateWithSubpredicates: [predicate, datePredicate])
        }

        // Set up the fetchLimit based on filtering or searching
        if filter.oldestPostDate != nil || isSearching() == true {
            // If filtering by the oldestPostDate or searching, the fetchLimit should be disabled.
            fetchRequest.fetchLimit = 0
        } else {
            // If not filtering by the oldestPostDate or searching, set the fetchLimit to the default number of posts.
            fetchRequest.fetchLimit = Int(numberOfPostsPerSync())
        }

        fetchRequest.predicate = predicate
        fetchRequest.sortDescriptors = sortDescriptors

        do {
            try tableViewHandler.resultsController.performFetch()
        } catch {
            DDLogError("Error fetching posts after updating the fetch request predicate: \(error)")
        }
    }

    func updateAndPerformFetchRequestRefreshingResults() {
        updateAndPerformFetchRequest()
        tableView.reloadData()
        refreshResults()
    }

    func resetTableViewContentOffset(_ animated: Bool = false) {
        // Reset the tableView contentOffset to the top before we make any dataSource changes.
        var tableOffset = tableView.contentOffset
        tableOffset.y = -tableView.contentInset.top
        tableView.setContentOffset(tableOffset, animated: animated)
    }

    func predicateForFetchRequest() -> NSPredicate {
        fatalError("You should implement this method in the subclass")
    }

    // MARK: - Table View Handling

    func tableView(_ tableView: UITableView, estimatedHeightForRowAt indexPath: IndexPath) -> CGFloat {
        // When using UITableViewAutomaticDimension for auto-sizing cells, UITableView
        // likes to reload rows in a strange way.
        // It uses the estimated height as a starting value for reloading animations.
        // So this estimated value needs to be as accurate as possible to avoid any "jumping" in
        // the cell heights during reload animations.
        // Note: There may (and should) be a way to get around this, but there is currently no obvious solution.
        // Brent C. August 2/2016
        if let height = estimatedHeightsCache.object(forKey: indexPath as AnyObject) as? CGFloat {
            // Return the previously known height as it was cached via willDisplayCell.
            return height
        }
        // Otherwise return whatever we have set to the tableView explicitly, and ideally a pretty close value.
        return tableView.estimatedRowHeight
    }

    func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        return UITableViewAutomaticDimension
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        assert(false, "You should implement this method in the subclass")
    }

    func tableViewDidChangeContent(_ tableView: UITableView) {
        refreshResults()
    }

    func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {

        // Cache the cell's layout height as the currently known height, for estimation.
        // See estimatedHeightForRowAtIndexPath
        estimatedHeightsCache.setObject(cell.frame.height as AnyObject, forKey: indexPath as AnyObject)

        guard isViewOnScreen() && !isSearching() else {
            return
        }

        // Are we approaching the end of the table?
        if indexPath.section + 1 == tableView.numberOfSections
            && indexPath.row + type(of: self).postsLoadMoreThreshold >= tableView.numberOfRows(inSection: indexPath.section) {

            // Only 3 rows till the end of table
            if filterSettings.currentPostListFilter().hasMore {
                syncHelper.syncMoreContent()
            }
        }
    }

    func configureCell(_ cell: UITableViewCell, at indexPath: IndexPath) {
        assert(false, "You should implement this method in the subclass")
    }

    // MARK: - Actions

    @IBAction func refresh(_ sender: AnyObject) {
        syncItemsWithUserInteraction(true)

        WPAnalytics.track(.postListPullToRefresh, withProperties: propertiesForAnalytics())
    }

    @IBAction func handleAddButtonTapped(_ sender: AnyObject) {
        createPost()
    }

    @IBAction func didTap(_ noResultsView: WPNoResultsView) {
        WPAnalytics.track(.postListNoResultsButtonPressed, withProperties: propertiesForAnalytics())

        createPost()
    }

    @IBAction func didTapFilterButton(_ sender: AnyObject) {
        displayFilters()
    }

    // MARK: - Synching

    func automaticallySyncIfAppropriate() {
        // Only automatically refresh if the view is loaded and visible on the screen
        if !isViewLoaded || view.window == nil {
            DDLogVerbose("View is not visible and will not check for auto refresh.")
            return
        }

        // Do not start auto-sync if connection is down
        let appDelegate = WordPressAppDelegate.sharedInstance()

        if appDelegate?.connectionAvailable == false {
            refreshResults()
            return
        }

        if let lastSynced = lastSyncDate(), abs(lastSynced.timeIntervalSinceNow) <= type(of: self).postsControllerRefreshInterval {

            refreshResults()
        } else {
            // Update in the background
            syncItemsWithUserInteraction(false)
        }
    }

    func syncItemsWithUserInteraction(_ userInteraction: Bool) {
        syncHelper.syncContentWithUserInteraction(userInteraction)
        refreshResults()
    }

    func updateFilter(_ filter: PostListFilter, withSyncedPosts posts: [AbstractPost], syncOptions options: PostServiceSyncOptions) {
        guard posts.count > 0 else {
            assertionFailure("This method should not be called with no posts.")
            return
        }
        // Reset the filter to only show the latest sync point, based on the oldest post date in the posts just synced.
        // Note: Getting oldest date manually as the API may return results out of order if there are
        // differing time offsets in the created dates.
        let oldestPost = posts.min {$0.date_created_gmt < $1.date_created_gmt}
        filter.oldestPostDate = oldestPost?.date_created_gmt
        filter.hasMore = posts.count >= options.number.intValue

        updateAndPerformFetchRequestRefreshingResults()
    }

    func numberOfPostsPerSync() -> UInt {
        return PostServiceDefaultNumberToSync
    }

    // MARK: - WPContentSyncHelperDelegate

    internal func postTypeToSync() -> PostServiceType {
        // Subclasses should override.
        return .any
    }

    func lastSyncDate() -> Date? {
        return blog.lastPostsSync
    }

    func syncHelper(_ syncHelper: WPContentSyncHelper, syncContentWithUserInteraction userInteraction: Bool, success: ((_ hasMore: Bool) -> ())?, failure: ((_ error: NSError) -> ())?) {

        if recentlyTrashedPostObjectIDs.count > 0 {
            refreshAndReload()
        }

        let filter = filterSettings.currentPostListFilter()
        let author = filterSettings.shouldShowOnlyMyPosts() ? blogUserID() : nil

        let postService = PostService(managedObjectContext: managedObjectContext())

        let options = PostServiceSyncOptions()
        options.statuses = filter.statuses.strings
        options.authorID = author
        options.number = numberOfPostsPerSync() as NSNumber!
        options.purgesLocalSync = true

        postService.syncPosts(
            ofType: postTypeToSync(),
            with: options,
            for: blog,
            success: {[weak self] posts in
                guard let strongSelf = self,
                    let posts = posts else {
                    return
                }

                if posts.count > 0 {
                    strongSelf.updateFilter(filter, withSyncedPosts: posts, syncOptions: options)
                }

                success?(filter.hasMore)

                if strongSelf.isSearching() {
                    // If we're currently searching, go ahead and request a sync with the searchText since
                    // an action was triggered to syncContent.
                    strongSelf.syncPostsMatchingSearchText()
                }

            }, failure: {[weak self] (error: Error?) -> () in

                guard let strongSelf = self,
                    let error = error else {
                    return
                }

                failure?(error as NSError)

                if userInteraction == true {
                    strongSelf.handleSyncFailure(error as NSError)
                }
        })
    }

    func syncHelper(_ syncHelper: WPContentSyncHelper, syncMoreWithSuccess success: ((_ hasMore: Bool) -> Void)?, failure: ((_ error: NSError) -> Void)?) {
        postListFooterView.showSpinner(true)

        let filter = filterSettings.currentPostListFilter()
        let author = filterSettings.shouldShowOnlyMyPosts() ? blogUserID() : nil

        let postService = PostService(managedObjectContext: managedObjectContext())

        let options = PostServiceSyncOptions()
        options.statuses = filter.statuses.strings
        options.authorID = author
        options.number = numberOfPostsPerSync() as NSNumber!
        options.offset = tableViewHandler.resultsController.fetchedObjects?.count as NSNumber!

        postService.syncPosts(
            ofType: postTypeToSync(),
            with: options,
            for: blog,
            success: {[weak self] posts in
                guard let strongSelf = self,
                    let posts = posts else {
                        return
                }

                if posts.count > 0 {
                    strongSelf.updateFilter(filter, withSyncedPosts: posts, syncOptions: options)
                }

                success?(filter.hasMore)
            }, failure: { (error) -> () in

                guard let error = error else {
                    return
                }

                failure?(error as NSError)
            })
    }

    func syncContentEnded(_ syncHelper: WPContentSyncHelper) {
        refreshControl?.endRefreshing()
        postListFooterView.showSpinner(false)

        noResultsView.removeFromSuperview()

        if tableViewHandler.resultsController.fetchedObjects?.count == 0 {
            // This is a special case.  Core data can be a bit slow about notifying
            // NSFetchedResultsController delegates about changes to the fetched results.
            // To compensate, call configureNoResultsView after a short delay.
            // It will be redisplayed if necessary.

            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + Double(Int64(100 * NSEC_PER_MSEC)) / Double(NSEC_PER_SEC), execute: { [weak self] in
                self?.refreshResults()
            })
        }
    }

    func handleSyncFailure(_ error: NSError) {
        if error.domain == WPXMLRPCFaultErrorDomain
            && error.code == type(of: self).HTTPErrorCodeForbidden {
            promptForPassword()
            return
        }

        WPError.showNetworkingAlertWithError(error, title: NSLocalizedString("Unable to Sync", comment: "Title of error prompt shown when a sync the user initiated fails."))
    }

    func promptForPassword() {
        let message = NSLocalizedString("The username or password stored in the app may be out of date. Please re-enter your password in the settings and try again.", comment: "")

        // bad login/pass combination
        let editSiteViewController = SiteSettingsViewController(blog: blog)

        let navController = UINavigationController(rootViewController: editSiteViewController!)
        navController.navigationBar.isTranslucent = false

        navController.modalTransitionStyle = .crossDissolve
        navController.modalPresentationStyle = .formSheet

        WPError.showAlert(withTitle: NSLocalizedString("Unable to Connect", comment: ""), message: message, withSupportButton: true) { _ in
            self.present(navController, animated: true, completion: nil)
        }
    }


    // MARK: - Searching

    func isSearching() -> Bool {
        return searchController.isActive && currentSearchTerm()?.characters.count > 0
    }

    func currentSearchTerm() -> String? {
        return searchController.searchBar.text
    }

    func updateForLocalPostsMatchingSearchText() {
        updateAndPerformFetchRequest()
        tableView.reloadData()

        let filter = filterSettings.currentPostListFilter()
        if filter.hasMore && tableViewHandler.resultsController.fetchedObjects?.count == 0 {
            // If the filter detects there are more posts, but there are none that match the current search
            // hide the no results view while the upcoming syncPostsMatchingSearchText() may in fact load results.
            hideNoResultsView()
            postListFooterView.isHidden = true
        } else {
            refreshResults()
        }
    }

    func isSyncingPostsWithSearch() -> Bool {
        return searchesSyncing > 0
    }

    func postsSyncWithSearchDidBegin() {
        searchesSyncing += 1
        postListFooterView.showSpinner(true)
        postListFooterView.isHidden = false
    }

    func postsSyncWithSearchEnded() {
        searchesSyncing -= 1
        assert(searchesSyncing >= 0, "Expected Int searchesSyncing to be 0 or greater while searching.")
        if !isSyncingPostsWithSearch() {
            postListFooterView.showSpinner(false)
            refreshResults()
        }
    }

    func syncPostsMatchingSearchText() {
        guard let searchText = searchController.searchBar.text, !searchText.isEmpty() else {
            return
        }
        let filter = filterSettings.currentPostListFilter()
        guard filter.hasMore else {
            return
        }

        postsSyncWithSearchDidBegin()

        let author = filterSettings.shouldShowOnlyMyPosts() ? blogUserID() : nil
        let postService = PostService(managedObjectContext: managedObjectContext())
        let options = PostServiceSyncOptions()
        options.statuses = filter.statuses.strings
        options.authorID = author
        options.number = 20
        options.purgesLocalSync = false
        options.search = searchText

        postService.syncPosts(
            ofType: postTypeToSync(),
            with: options,
            for: blog,
            success: { [weak self] posts in
                self?.postsSyncWithSearchEnded()
            }, failure: { [weak self] (error) in
                self?.postsSyncWithSearchEnded()
            }
        )
    }

    // MARK: - Actions

    func publishPost(_ apost: AbstractPost) {
        WPAnalytics.track(.postListPublishAction, withProperties: propertiesForAnalytics())

        apost.date_created_gmt = Date()
        apost.status = .publish
        uploadPost(apost)
    }

    func schedulePost(_ apost: AbstractPost) {
        WPAnalytics.track(.postListScheduleAction, withProperties: propertiesForAnalytics())

        apost.status = .scheduled
        uploadPost(apost)
    }

    fileprivate func uploadPost(_ apost: AbstractPost) {
        let postService = PostService(managedObjectContext: ContextManager.sharedInstance().mainContext)

        postService.uploadPost(apost, success: nil) { [weak self] (error: Error?) in

            let error = error as NSError?
            guard let strongSelf = self else {
                return
            }

            if error?.code == type(of: strongSelf).HTTPErrorCodeForbidden {
                strongSelf.promptForPassword()
            } else {
                WPError.showXMLRPCErrorAlert(error)
            }

            strongSelf.syncItemsWithUserInteraction(false)
        }
    }

    func viewPost(_ apost: AbstractPost) {
        WPAnalytics.track(.postListViewAction, withProperties: propertiesForAnalytics())

        let post = apost.hasRevision() ? apost.revision! : apost

        let controller = PostPreviewViewController(post: post)
        // NOTE: We'll set the title to match the title of the View action button.
        // If the button title changes we should also update the title here.
        controller.navigationItem.title = NSLocalizedString("View", comment: "Verb. The screen title shown when viewing a post inside the app.")
        controller.hidesBottomBarWhenPushed = true
        navigationController?.pushViewController(controller, animated: true)
    }

    func deletePost(_ apost: AbstractPost) {
        WPAnalytics.track(.postListTrashAction, withProperties: propertiesForAnalytics())

        let postObjectID = apost.objectID

        recentlyTrashedPostObjectIDs.append(postObjectID)

        // Update the fetch request *before* making the service call.
        updateAndPerformFetchRequest()

        let indexPath = tableViewHandler.resultsController.indexPath(forObject: apost)

        if let indexPath = indexPath {
            tableView.reloadRows(at: [indexPath], with: .fade)
        }

        let postService = PostService(managedObjectContext: ContextManager.sharedInstance().mainContext)

        postService.trashPost(apost, success: nil) { [weak self] (error) in

            guard let strongSelf = self else {
                return
            }

            if let error = error as NSError?, error.code == type(of: strongSelf).HTTPErrorCodeForbidden {
                strongSelf.promptForPassword()
            } else {
                WPError.showXMLRPCErrorAlert(error)
            }

            if let index = strongSelf.recentlyTrashedPostObjectIDs.index(of: postObjectID) {
                strongSelf.recentlyTrashedPostObjectIDs.remove(at: index)
                // We don't really know what happened here, why did the request fail?
                // Maybe we could not delete the post or maybe the post was already deleted
                // It is safer to re fetch the results than to reload that specific row
                DispatchQueue.main.async {
                    strongSelf.updateAndPerformFetchRequestRefreshingResults()
                }
            }
        }
    }

    func restorePost(_ apost: AbstractPost) {
        WPAnalytics.track(.postListRestoreAction, withProperties: propertiesForAnalytics())

        // if the post was recently deleted, update the status helper and reload the cell to display a spinner
        let postObjectID = apost.objectID

        if let index = recentlyTrashedPostObjectIDs.index(of: postObjectID) {
            recentlyTrashedPostObjectIDs.remove(at: index)
        }

        let postService = PostService(managedObjectContext: ContextManager.sharedInstance().mainContext)

        postService.restore(apost, success: { [weak self] in

            guard let strongSelf = self else {
                return
            }

            var apost: AbstractPost

            // Make sure the post still exists.
            do {
                apost = try strongSelf.managedObjectContext().existingObject(with: postObjectID) as! AbstractPost
            } catch {
                DDLogError("\(error)")
                return
            }

            if let postStatus = apost.status {
                // If the post was restored, see if it appears in the current filter.
                // If not, prompt the user to let it know under which filter it appears.
                let filter = strongSelf.filterSettings.filterThatDisplaysPostsWithStatus(postStatus)

                if filter.filterType == strongSelf.filterSettings.currentPostListFilter().filterType {
                    return
                }

                strongSelf.promptThatPostRestoredToFilter(filter)
            }
        }) { [weak self] (error) in

            guard let strongSelf = self else {
                return
            }

            if let error = error as NSError?, error.code == type(of: strongSelf).HTTPErrorCodeForbidden {
                strongSelf.promptForPassword()
            } else {
                WPError.showXMLRPCErrorAlert(error)
            }

            strongSelf.recentlyTrashedPostObjectIDs.append(postObjectID)
        }
    }

    func promptThatPostRestoredToFilter(_ filter: PostListFilter) {
        assert(false, "You should implement this method in the subclass")
    }

    // MARK: - Post Actions

    func createPost() {
        assert(false, "You should implement this method in the subclass")
    }

    // MARK: - Data Sources

    /// Retrieves the userID for the user of the current blog.
    ///
    /// - Returns: the userID for the user of the current WPCom blog.  If the blog is not hosted at
    ///     WordPress.com, `nil` is returned instead.
    ///
    func blogUserID() -> NSNumber? {
        return blog.userID
    }

    // MARK: - Filtering

    func refreshAndReload() {
        recentlyTrashedPostObjectIDs.removeAll()
        updateFilterTitle()
        resetTableViewContentOffset()
        updateAndPerformFetchRequestRefreshingResults()
    }

    func updateFilterWithPostStatus(_ status: BasePost.Status) {
        filterSettings.setFilterWithPostStatus(status)
        refreshAndReload()
        WPAnalytics.track(.postListStatusFilterChanged, withProperties: propertiesForAnalytics())
    }

    func updateFilter(index: Int) {
        filterSettings.setCurrentFilterIndex(index)
        refreshAndReload()
    }

    func updateFilterTitle() {
        filterButton.setAttributedTitleForTitle(filterSettings.currentPostListFilter().title)
    }

    func displayFilters() {
        let availableFilters = filterSettings.availablePostListFilters()

        let titles = availableFilters.map { (filter: PostListFilter) -> String in
            return filter.title
        }

        let dict = [SettingsSelectionDefaultValueKey: availableFilters[0],
                    SettingsSelectionTitleKey: NSLocalizedString("Filters", comment: "Title of the list of post status filters."),
                    SettingsSelectionTitlesKey: titles,
                    SettingsSelectionValuesKey: availableFilters,
                    SettingsSelectionCurrentValueKey: filterSettings.currentPostListFilter()] as [String: Any]

        let controller = SettingsSelectionViewController(style: .plain, andDictionary: dict as [AnyHashable: Any])
        controller?.onItemSelected = { [weak self] (selectedValue: Any!) -> () in
            if let strongSelf = self,
                let index = strongSelf.filterSettings.availablePostListFilters().index(of: selectedValue as! PostListFilter) {

                strongSelf.filterSettings.setCurrentFilterIndex(index)
                strongSelf.dismiss(animated: true, completion: nil)

                strongSelf.refreshAndReload()
                strongSelf.syncItemsWithUserInteraction(false)

                WPAnalytics.track(.postListStatusFilterChanged, withProperties: strongSelf.propertiesForAnalytics())
            }
        }

        controller?.tableView.isScrollEnabled = false

        displayFilterPopover(controller!)
    }

    func displayFilterPopover(_ controller: UIViewController) {
        controller.preferredContentSize = type(of: self).preferredFiltersPopoverContentSize

        guard let titleView = navigationItem.titleView else {
            return
        }

        ForcePopoverPresenter.configurePresentationControllerForViewController(controller, presentingFromView: titleView)

        present(controller, animated: true, completion: nil)
    }

    // MARK: - Search Controller Delegate Methods

    func willPresentSearchController(_ searchController: UISearchController) {
        WPAnalytics.track(.postListSearchOpened, withProperties: propertiesForAnalytics())
    }

    func willDismissSearchController(_ searchController: UISearchController) {
        searchController.searchBar.text = nil
        searchHelper.searchCanceled()

        tableView.scrollIndicatorInsets.top = topLayoutGuide.length
    }

    func updateSearchResults(for searchController: UISearchController) {
        resetTableViewContentOffset()
        searchHelper.searchUpdated(searchController.searchBar.text)
    }
}
