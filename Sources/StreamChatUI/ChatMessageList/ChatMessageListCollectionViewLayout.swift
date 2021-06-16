//
// Copyright © 2021 Stream.io Inc. All rights reserved.
//

import UIKit

public class MessageLayoutInvalidationContext: UICollectionViewLayoutInvalidationContext {
    public var invalidateVisibleSizeRelatedMetrics: Bool = false

    /// When `true` the layout should recalculate all offsets of the existing items. This usually happens
    /// when the content is smaller than the visible area.
    public var invalidateItemsOffsets: Bool = false

    public var restoreBottomEdgeDistance: CGFloat?

    public var forceContentSizeChanges: Bool = false
}

/// Custom Table View like layout that position item at index path 0-0 on bottom of the list.
///
/// Unlike `UICollectionViewFlowLayout` we ignore some invalidation calls and persist items attributes between updates.
/// This resolves problem when on item reload layout would change content offset and user ends up on completely different item.
/// Layout intended for batch updates and right now I have no idea how it will react to `collectionView.reloadData()`.
open class ChatMessageListCollectionViewLayout: UICollectionViewLayout {
    /// Layout items before currently running batch update
    open var previousItems: [LayoutItem] = []

    /// Actual layout
    open var currentItems: [LayoutItem] = []
//    {
//        didSet {
//            print("\n======= current items ====== ")
//            currentItems.forEach {
//                print("    -> \($0.offset) | \($0.height)")
//            }
//        }
//    }

    /// Future layout to be used when the invalidation process finishes
    open var futureItems: [LayoutItem]? = []
    //    {
    //        didSet {
    //            print("\n======= futureItems items ====== ")
    //            currentItems.forEach {
    //                print("    -> \($0.offset) | \($0.height)")
    //            }
    //        }
    //    }

    open var cachedCurrentItems: [LayoutItem] = []

    /// You can improve scroll performance by tweaking this number. In general, it's better to keep this number a little
    /// bit higher than the average cell height.
    open var estimatedItemHeight: CGFloat = 150

    /// Vertical spacing between items
    open var spacing: CGFloat = 2

    /// Items that have been added to collectionview during currently running batch updates
    open var appearingItems: Set<IndexPath> = []
    /// Items that have been removed from collectionview during currently running batch updates
    open var disappearingItems: Set<IndexPath> = []

    /// We need to cache attributes used for initial/final state of added/removed items to update them after AutoLayout pass.
    /// This will prevent items to appear with `estimatedItemHeight` and animating to real size
//    open var animatingAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:]

    // =========================

    override open class var invalidationContextClass: AnyClass {
        MessageLayoutInvalidationContext.self
    }

    public var previousContentInsets: UIEdgeInsets = .zero {
        didSet {
            print("previous content inset set: \(previousContentInsets)")
        }
    }

    public var previousContentSize: CGSize = .zero {
        didSet {
            print("previous content size set: \(previousContentSize)")
        }
    }

    /// This is the minimal content size heigh reported to the collection view. We use this constant to easily keep the messages
    /// pinned to the bottom of the screen. This value always be higher than the max visible height of the device. Don't make this
    /// value unnecessarily big because the higher the value the biggest performance penalty.
    open var minimalContentHeight: CGFloat = 3000

    override open var collectionViewContentSize: CGSize {
        // This is a workaround for `layoutAttributesForElementsInRect:` not getting invoked enough
        // times if `collectionViewContentSize.width` is not smaller than the width of the collection
        // view, minus horizontal insets. This results in visual defects when performing batch
        // updates. To work around this, we subtract 0.0001 from our content size width calculation;
        // this small decrease in `collectionViewContentSize.width` is enough to work around the
        // incorrect, internal collection view `CGRect` checks, without introducing any visual
        // differences for elements in the collection view.
        // See https://openradar.appspot.com/radar?id=5025850143539200 for more details.
        //
        // Credit to https://github.com/airbnb/MagazineLayout/blob/6f88742c282de208e48cb738a7a14b7dc2651701/MagazineLayout/Public/MagazineLayout.swift#L69

        let result = CGSize(
            width: collectionView!.bounds.width - 0.001,
            height: max(minimalContentHeight, currentItems.first?.maxY ?? 0)
        )

        print("❔ CollectionView content size request: \(result)")
        return result
    }

    open var collectionViewVisibleSize: CGSize = .zero {
        didSet {
            print("collectionViewVisibleSize set: \(collectionViewVisibleSize)")
        }
    }

    /// Used to prevent layout issues during batch updates.
    ///
    /// Before batch updates collection view says to invalidate layout with `invalidateDataSourceCounts`.
    /// Next it ask us for attributes for new items before says which items are new. So we have no way to properly calculate it.
    /// `UICollectionViewFlowLayout` uses private API to get this info. We are don not have such privilege.
    /// If we return wrong attributes user will see artifacts and broken layout during batch update animation.
    /// By not returning any attributes during batch updates we are able to prevent such artifacts.
    open var preBatchUpdatesCall = false

    open var wasScrolledToBottom = false

    /// As we very often need to preserve scroll offset after performBatchUpdates, the simplest solution is to save original
    /// contentOffset and set it when batch updates end
    private var restoreOffset: CGFloat? {
        didSet {
            print("restore offset: \(restoreOffset ?? 0)")
        }
    }

    private var topEmptyInset: CGFloat = 0 {
        didSet {
            print("*** topEmptyInset: \(topEmptyInset)")
        }
    }

    /// Flag to make sure the `prepare()` function is only executed when the collection view had been loaded.
    /// The rest of the updates should come from `prepare(forCollectionViewUpdates:)`.
    private var didPerformInitialLayout = false

    // MARK: - Cache

    // MARK: - Initialization

    override public required init() {
        super.init()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Prepare

    override open func prepare() {
        super.prepare()

        print("\n👉 \(#function)")
        defer { print("\(#function) 👈") }

        guard let collectionView = self.collectionView else {
            print(" * collectionView is `nil`")
            return
        }

        collectionViewVisibleSize = CGSize(
            width: collectionView.bounds.width,
            height: collectionView.bounds.height
                - collectionView.contentInset.top
                - collectionView.contentInset.bottom
        )

        previousContentInsets = collectionView.contentInset

        if let restoreBottomDistance = currentInvalidationContent?.restoreBottomEdgeDistance {
            let restoreOffset = CGPoint(x: 0, y: resolveRestoreOffset(restoreBottomDistance))
            print(" * setting the restore content offset to \(restoreOffset)")
            collectionView.setContentOffset(restoreOffset, animated: false)
        }

        if let futureItems = self.futureItems {
            currentItems = futureItems
            self.futureItems = nil
        }

        // Skipped the rest if we have cached data already
        guard currentItems.isEmpty else { return }

        let itemsCount = collectionView.numberOfItems(inSection: 0)
        guard itemsCount > 0 else {
            print(" * items count is 0, nothing to do here")
            return
        }

        // Create initial items
        for _ in 0..<itemsCount {
            // The offset doesn't matter at this case since it will be calculated properly in the next step
            currentItems.append(LayoutItem(offset: 0, height: estimatedItemHeight))
        }

        recalculateLayout(items: &currentItems, visibleHeight: collectionViewContentSize.height)

        // Set the initial content offset to the last page
        let lastPageYOffset = collectionViewContentSize.height - collectionViewVisibleSize.height
        let initialContentOffset = CGPoint(x: 0, y: lastPageYOffset)
        print(" * setting the initial content offset to \(initialContentOffset)")
        collectionView.setContentOffset(initialContentOffset, animated: false)
    }

    var restoreBottomEdgeDistance: CGFloat = 0

    override open func prepare(forAnimatedBoundsChange oldBounds: CGRect) {
        super.prepare(forAnimatedBoundsChange: oldBounds)

        print("\n👉 \(#function): Old bounds \(oldBounds) | New bounds: \(collectionView!.bounds)")
        defer { print("\(#function) 👈") }

        isAnimatedBoundsChangeInProgress = true
        previousItems = currentItems
    }

    // MARK: - Finalize

    override open func finalizeCollectionViewUpdates() {
        print("\n👉 \(#function)")
        defer { print("\(#function) 👈") }

        currentInvalidationContent = nil

        preBatchUpdatesCall = false
        updateFinalContentSize()
    }

    override open func finalizeAnimatedBoundsChange() {
        super.finalizeAnimatedBoundsChange()

        print("\n👉 \(#function)")
        defer { print("\(#function) 👈") }

        currentInvalidationContent = nil
        isAnimatedBoundsChangeInProgress = false

        preBatchUpdatesCall = false
        updateFinalContentSize()

        preBoundsChangeContentSize = nil

        super.finalizeCollectionViewUpdates()
    }

    // MARK: - Content offset

    override open func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        proposedContentOffset
    }

    // MARK: - Layout invalidation

    var currentInvalidationContent: MessageLayoutInvalidationContext?
    var preBoundsChangeContentSize: CGSize?

    override open func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        print("\n👉 \(#function)")
        defer { print("\(#function) 👈") }

        let context = context as! MessageLayoutInvalidationContext

        preBatchUpdatesCall = context.invalidateDataSourceCounts && !context.invalidateEverything
        currentInvalidationContent = context

        print(" * content size adjustment: \(context.contentSizeAdjustment.height)")
        print(" * content offset adjustment: \(context.contentOffsetAdjustment.y)")

        if !context.forceContentSizeChanges && collectionViewContentSize.height == minimalContentHeight {
            print(" * resetting adjustments because contentSize < minimalContentHeight")
            context.contentSizeAdjustment = .zero
            context.contentOffsetAdjustment = .zero
        }

        super.invalidateLayout(with: context)
    }

    // MARK: - Contexts

    override open func invalidationContext(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutInvalidationContext {
        print("\n👉 \(#function): \(preferredAttributes.indexPath)")
        defer { print("\(#function) 👈") }

        let invalidationContext = super.invalidationContext(
            forPreferredLayoutAttributes: preferredAttributes,
            withOriginalAttributes: originalAttributes
        ) as! MessageLayoutInvalidationContext

        // Start preparing the future layout
        futureItems = currentItems

        let idx = preferredAttributes.indexPath.item

        let delta = preferredAttributes.frame.height - futureItems![idx].height

        // Update the item's height
        var item = futureItems![idx]
        item.height = preferredAttributes.frame.height
        if let cellAttributes = preferredAttributes as? MessageCellLayoutAttributes {
            item.layoutOptions = cellAttributes.layoutOptions
            item.previousLayoutOptions = cellAttributes.previousLayoutOptions
            item.label = cellAttributes.label
            item.isInitial = false
        }

        item.label += "_adjusted"
        futureItems![idx] = item

        // Update the offset of the cells below the updated one
        for i in 0..<idx {
            futureItems![i].offset += delta
        }

        let isCurrentContentBiggerThenMin = isContentBiggerThan(items: currentItems, height: collectionViewContentSize.height)
        let isFutureContentBiggerThenMin = isContentBiggerThan(items: futureItems!, height: collectionViewContentSize.height)

        // If the content changes such that it affects the initial page, always recreate the whole layout
        if !isCurrentContentBiggerThenMin || !isFutureContentBiggerThenMin {
            recalculateLayout(items: &futureItems!, visibleHeight: collectionViewContentSize.height)
        }

        // If we crossed the minContent boundary we have to adjust the content size
        if isCurrentContentBiggerThenMin != isFutureContentBiggerThenMin {
            let currentTopOverflow = currentItems.last?.offset ?? 0
            let futureTopOverflow = futureItems!.last?.offset ?? 0

            let contentSizeDelta = currentTopOverflow - futureTopOverflow
            invalidationContext.contentSizeAdjustment = CGSize(width: 0, height: contentSizeDelta)

        } else if isCurrentContentBiggerThenMin && isFutureContentBiggerThenMin {
            invalidationContext.contentSizeAdjustment = CGSize(width: 0, height: delta)
        }

//        if wasScrolledToBottom {
//            invalidationContext.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
//            return invalidationContext
//        }

        // when we scrolling up and item above screens top edge changes its attributes it will push all items below it to bottom
        // making unpleasant jump. To prevent it we need to adjust current content offset by item delta
        let isSizingElementAboveTopEdge = originalAttributes.frame.minY < (collectionView?.contentOffset.y ?? 0)

        if isSizingElementAboveTopEdge {
            invalidationContext.contentOffsetAdjustment = CGPoint(x: 0, y: delta)
        }

        invalidationContext.forceContentSizeChanges = true

        return invalidationContext
    }

    override open func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        print("\n👉 \(#function) Old bounds \(collectionView!.bounds) | New bounds: \(newBounds)")
        defer { print("\(#function) 👈") }

        let context = super.invalidationContext(forBoundsChange: newBounds) as! MessageLayoutInvalidationContext
        guard let collectionView = collectionView else { return context }

        if !collectionView.isScrolling {
            // Save the current visual distance from the bottom edge
            context.restoreBottomEdgeDistance = getRestoreOffset()
        } else {
            print(" * skipping storing the restore offset because the CV is scrolling")
        }

        return context
    }

    override open func shouldInvalidateLayout(
        forPreferredLayoutAttributes preferredAttributes: UICollectionViewLayoutAttributes,
        withOriginalAttributes originalAttributes: UICollectionViewLayoutAttributes
    ) -> Bool {
        preferredAttributes.size.height != originalAttributes.size.height
    }

    var previousInitialAttributes: [IndexPath: UICollectionViewLayoutAttributes] = [:] {
        didSet {
            print("------ previous initial attributes -----")
            previousInitialAttributes.forEach {
                print("     * \($0.value.frame.origin)")
            }
        }
    }

    override open func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        guard let cv = collectionView else { return true }
        let result = cv.bounds.size != newBounds.size || cv.contentInset != previousContentInsets
        return result
    }

    func isContentBiggerThan(items: [LayoutItem], height: CGFloat) -> Bool {
        guard let first = items.first, let last = items.last else { return false }
        return first.maxY - last.offset > height
    }

    var isContentBiggerThanOnePage: Bool {
        currentItems.last!.offset == 0 && currentItems.first!.maxY > collectionViewVisibleSize.height
    }

    var newBoundsDelta: CGFloat?
    var isAnimatedBoundsChangeInProgress: Bool = false

//    override open func prepare(forAnimatedBoundsChange oldBounds: CGRect) {
//        super.prepare(forAnimatedBoundsChange: oldBounds)
//
//        print("PREPARE FOR ANIMATED BOUNDS CHANGE: \(collectionView!.bounds.height)")
//
//        isAnimatedBoundsChangeInProgress = true
//        newBoundsDelta = collectionView!.bounds.height - oldBounds.height
//
    ////        previousItems = currentItems
//
//        if !isContentBiggerThan(height: collectionView!.bounds.height) {
    ////            recalculateLayout(visibleHeight: collectionViewVisibleSize.height)
//        } else {
//            print("Content not bigger, skipping recalculation.")
//        }
//    }

//    override open func finalizeAnimatedBoundsChange() {
//        super.finalizeAnimatedBoundsChange()
//        isAnimatedBoundsChangeInProgress = false
//        newBoundsDelta = nil
//
    ////        animatingAttributes = [:]
//
//        CATransaction.setCompletionBlock {
//            if !self.isContentBiggerThan(height: self.collectionView!.bounds.height) {
//                let context = self
//                    .invalidationContext(forBoundsChange: self.collectionView!.bounds) as! MessageLayoutInvalidationContext
//                context.invalidateVisibleSizeRelatedMetrics = true
//                self.invalidateLayout(with: context)
//            }
//        }
//
    ////        if let animationKeys = collectionView!.layer.animationKeys(), animationKeys.isEmpty == false {
    ////            print("RUNNING ANIMATI")
    ////        }
    ////
//        print("* FINALIZE BOUNDS CHANGE")
//    }

    var isScrolledToBottom: Bool {
        guard let cv = collectionView else { return false }

        return collectionViewContentSize.height
            - cv.contentOffset.y
            - collectionViewVisibleSize.height
            <= cv.contentInset.top
    }

    // MARK: - Animation updates

    open func _prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        preBatchUpdatesCall = true

        print("-> prepareForCollectionViewUpdates ")

        guard let cv = collectionView else { return }

        collectionViewVisibleSize = CGSize(
            width: cv.bounds.width,
            height: cv.bounds.height - cv.adjustedContentInset.top - cv.adjustedContentInset.bottom
        )

        wasScrolledToBottom = isScrolledToBottom

        print(collectionViewVisibleSize.height)

        // used to determine what contentOffset should be restored after batch updates
//        if !isContentBiggerThanOnePage {
//            restoreOffset = currentItems.last?.offset
//        }

        let wasContentBiggerThanOnePage = isContentBiggerThanOnePage

        let delete: (UICollectionViewUpdateItem) -> Void = { update in
            guard let ip = update.indexPathBeforeUpdate else { return }
            let idx = ip.item
            let item = self.previousItems[idx]
            self.disappearingItems.insert(ip)
            var delta = item.height

            print("delete item \(ip.item) at offset \(item.offset)")

            if idx > 0 {
                delta += self.spacing
            }
            for i in 0..<idx {
                guard let oldId = self.oldIdForItem(at: i) else { return }
                
                if let idx = self.indexForItem(with: oldId) {
                    self.currentItems[idx].offset -= delta
                }
            }
            
            if let idx = self.indexForItem(with: item.id) {
                self.currentItems.remove(at: idx)
            }
        }

        let insert: (UICollectionViewUpdateItem) -> Void = { update in
            guard let ip = update.indexPathAfterUpdate else { return }
            self.appearingItems.insert(ip)
            let idx = ip.item
            var item: LayoutItem

            // The offset of the last (top-most) element in the layout. This values is non-zero if we don't have enough
            // elements to cover the whole vertical page.
            let lastItemOffset = self.currentItems.last?.offset ?? 0

            if idx == self.currentItems.count {
                let offset = max(0, lastItemOffset - self.estimatedItemHeight - self.spacing)
                item = LayoutItem(offset: offset, height: self.estimatedItemHeight)

            } else {
                item = LayoutItem(
                    offset: self.currentItems[idx].maxY + self.spacing,
                    height: self.currentItems[idx].height
                )
            }

            item.label = "init"

            print("inserting item \(ip.item) at offset \(item.offset)")

            let delta = item.height
                + self.spacing
                - lastItemOffset

            for i in 0..<idx {
                self.currentItems[i].offset += delta
            }

            self.currentItems.insert(item, at: idx)
        }

        for update in updateItems {
            switch update.updateAction {
            case .delete:
                delete(update)
            case .insert:
                insert(update)
            case .move:
                delete(update)
                insert(update)
            case .reload, .none: break
            @unknown default: break
            }
        }

        if !wasContentBiggerThanOnePage || !isContentBiggerThanOnePage {
//            recalculateLayout(visibleHeight: collectionViewVisibleSize.height)
        }

        preBatchUpdatesCall = false

        print("prepareForCollectionViewUpdates <-\n")
    }
    
    /// Only public by design, if you need to override this method override `_prepare(forCollectionViewUpdates:)`
    override public func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        print("prepare forCollectionViewUpdates")

        // In Xcode 12.5 it is impossible to use own `updateItems` - our solution with `UICollectionViewUpdateItem` subclass stopped working
        // (Apple is probably checking some private API and our customized getters are not called),
        // so instead of testing `prepare(forCollectionViewUpdates:)` we will test our custom function
        _prepare(forCollectionViewUpdates: updateItems)
        super.prepare(forCollectionViewUpdates: updateItems)
    }

    // MARK: - Main layout access

    override open func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard !preBatchUpdatesCall, let cv = collectionView else { return nil }

//        var rect = rect
//        let minHeight = 2 * cv.bounds.height
//
//        if rect.height < minHeight {
//            let diff = minHeight - rect.height
//            rect.origin.y -= diff / 2.0
//            rect.size.height = minHeight
//        }

        let result: [UICollectionViewLayoutAttributes] = currentItems
            .enumerated()
            .filter { _, item in
                let itemFrame = CGRect(x: 0, y: item.offset, width: rect.width, height: item.height)
                return rect.intersects(itemFrame)
            }
            .compactMap {
                let indexPath = IndexPath(item: indexForItem(with: $0.element.id)!, section: 0)
                return layoutAttributesForItem(at: indexPath) as! MessageCellLayoutAttributes
            }
            .sorted(by: { $0.indexPath < $1.indexPath })

//        print("⏱ returning attributes \(result.map { $0.indexPath.description }.joined(separator: " | "))")

        return result
    }

    // MARK: - Layout for collection view items

    override open func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard !preBatchUpdatesCall else { return nil }

        guard indexPath.item < currentItems.count else { return nil }
        let idx = indexPath.item

        let attributes = currentItems[idx].attribute(for: idx, width: collectionViewVisibleSize.width)

        if indexPath.item != 0 && appearingItems.contains(indexPath) {
            // Newly inserted messages at other than 0-0 index paths is a pagination insert -> no animations
            attributes.isChangeAnimated = false
        }

        if isAnimatedBoundsChangeInProgress {
            // The bounds changes should not be animated on the cell content level
            attributes.isChangeAnimated = false
        }

        attributes.transform = .identity

        return attributes
    }

    override open func targetContentOffset(
        forProposedContentOffset proposedContentOffset: CGPoint,
        withScrollingVelocity velocity: CGPoint
    ) -> CGPoint {
        let maxOffset = collectionViewContentSize.height - collectionViewVisibleSize.height
        let contentStartOffset = currentItems.last?.offset ?? maxOffset

        var proposedContentOffset = proposedContentOffset
        proposedContentOffset.y = min(maxOffset, max(proposedContentOffset.y, contentStartOffset))

        return proposedContentOffset
    }

//
//    open override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
//        guard isAnimatedBoundsChangeInProgress else { return nil }
//
//        if let cached = previousInitialAttributes[itemIndexPath] as? MessageCellLayoutAttributes {
//            cached.label = "cached"
//            cached.isCachedAttribute = true
//            cached.isChangeAnimated = true
//            return cached
//        }
//
//        let attr = previousItems[itemIndexPath.item]
//            .attribute(for: itemIndexPath.item, width: collectionViewContentSize.width)
//
    ////        attr.isChangeAnimated = true
//        attr.alpha = 1
//
//        attr.label = "initial for appearing"
//        attr.isInitialAttributes = true
//        attr.isChangeAnimated = true
//
//
//        attr.frame.size.height = estimatedItemHeight
//
//        print("Initial attributes for \(itemIndexPath): \(attr.frame)")
//
//        previousInitialAttributes[itemIndexPath] = attr
//
//        return attr
//    }

//    open override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
//
    ////        if let cached = previousInitialAttributes[itemIndexPath] as? MessageCellLayoutAttributes {
    ////            cached.isChangeAnimated = true
    ////            cached.transform = CGAffineTransform(translationX: 0, y: newBoundsDelta!)
    ////            return cached
    ////        }
//
//        let attr = currentItems[itemIndexPath.item].attribute(for: itemIndexPath.item, width: collectionViewVisibleSize.width)
//        attr.label = "finalLayoutAttributes"
//        attr.isChangeAnimated = false
//
//        previousInitialAttributes[itemIndexPath] = attr.copy() as! MessageCellLayoutAttributes
//
//        return attr
//    }

//    open override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
//        guard isAnimatedBoundsChangeInProgress, let boundsDelta = newBoundsDelta else { return nil }
//
    ////        if let cached = previousInitialAttributes[itemIndexPath] as? MessageCellLayoutAttributes {
    ////            cached.label = "cached"
    ////            cached.isCachedAttribute = true
    ////            cached.isChangeAnimated = true
    ////            return cached
    ////        }
//
//        print(" **** final layou attributes for \(itemIndexPath)")
//
//        let attr = previousItems[itemIndexPath.item]
//            .attribute(for: itemIndexPath.item, width: collectionViewContentSize.width)
//
//        attr.label = "final"
    ////        attr.isChangeAnimated = false
//
    ////        attr.isChangeAnimated = true
    ////        attr.alpha = 0
//
//        // OK, this is a terrible workaround 🙈
    ////        if boundsDelta > 0 {
    ////            attr.transform = CGAffineTransform(translationX: 0, y: -34)
    ////        } else {
    ////            attr.transform = CGAffineTransform(translationX: 0, y: 34)
    ////        }
//
//        return attr
//    }

//    open override func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
//        if let boundsDiff = newBoundsDelta {
//            let attributes = previousItems[itemIndexPath.item]
//                .attribute(for: itemIndexPath.item, width: collectionViewContentSize.width)
    ////            attributes.isChangeAnimated = false
    ////            attributes.center.y -= boundsDiff
//            return attributes
//
//        } else {
//            return nil
//        }
//    }

//    open override func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
//        if let boundsDiff = newBoundsDelta {
//            let attributes = currentItems[itemIndexPath.item]
//                .attribute(for: itemIndexPath.item, width: collectionViewContentSize.width)
    ////            attributes.isChangeAnimated =
    ////            attributes.center.y += boundsDiff
//            attributes.alpha = 1
//            attributes.isChangeAnimated = false
//            return attributes
//
//        } else {
//            return nil
//        }
//    }

//    override open func initialLayoutAttributesForAppearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
//        let itemIndex = itemIndexPath.item
//        if appearingItems.contains(itemIndexPath) {
//            // this is item that have been inserted into collection view in current batch update
//            let attribute = currentItems[itemIndex].attribute(for: itemIndex, width: collectionViewVisibleSize.width)
//
//            animatingAttributes[itemIndexPath] = attribute
//            return attribute
//        }
//
//        if let itemId = idForItem(at: itemIndex), let oldItemIndex = oldIndexForItem(with: itemId) {
//            // this is item that already presented in collection view, but collection view decided to reload it
//            // by removing and inserting it back (4head)
//            // to properly animate possible change of such item, we need to return its attributes BEFORE batch update
//            let itemStaysInPlace = itemIndex == oldItemIndex
//
//            let attribute = (itemStaysInPlace ? currentItems[itemIndex] : previousItems[oldItemIndex])
//                .attribute(for: itemStaysInPlace ? itemIndex : oldItemIndex, width: collectionViewVisibleSize.width)
//
    ////            if let boundsChangeOffset = self.boundsChangeOffset {
    ////                attribute.center.y += boundsChangeOffset
    ////            }
//
//            return attribute
//        }
//
//        let attribute = currentItems[itemIndex].attribute(for: itemIndex, width: collectionViewVisibleSize.width)
//
//        return  attribute
//
    ////        return super.initialLayoutAttributesForAppearingItem(at: itemIndexPath)
//    }
//
//    override open func finalLayoutAttributesForDisappearingItem(at itemIndexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
//        let idx = itemIndexPath.item
//        guard let id = oldIdForItem(at: idx) else { return nil }
//        if disappearingItems.contains(itemIndexPath) {
//            // item gets removed from collection view, we don't do any special delete animations for now, so just return
//            // item attributes BEFORE batch update and let it fade away
//            let attribute = previousItems[idx]
//                .attribute(for: idx, width: collectionViewContentSize.width)
//                .copy() as! UICollectionViewLayoutAttributes
//
//            attribute.alpha = 0
//            return attribute
//
//        } else if let newIdx = indexForItem(with: id) {
//            // this is item that will stay in collection view, but collection view decided to reload it
//            // by removing and inserting it back (4head)
//            // to properly animate possible change of such item, we need to return its attributes AFTER batch update
//            let attribute = currentItems[newIdx]
//                .attribute(for: newIdx, width: collectionViewContentSize.width)
//                .copy() as! UICollectionViewLayoutAttributes
//
//            animatingAttributes[attribute.indexPath] = attribute
    ////            attribute.alpha = 0
//            return attribute
//        }
//
//        if let newBoundsDelta = self.newBoundsDelta {
//            let attributes = currentItems[idx].attribute(for: itemIndexPath.item, width: collectionViewContentSize.width)
//            attributes.center.y += newBoundsDelta
//            attributes.isChangeAnimated = false
//            return attributes
//        }
//
//        return super.finalLayoutAttributesForDisappearingItem(at: itemIndexPath)
//    }

    // MARK: - Access Layout Item

    open func idForItem(at idx: Int) -> UUID? {
        guard currentItems.indices.contains(idx) else { return nil }
        return currentItems[idx].id
    }

    open func indexForItem(with id: UUID) -> Int? {
        currentItems.firstIndex { $0.id == id }
    }

    open func oldIdForItem(at idx: Int) -> UUID? {
        guard previousItems.indices.contains(idx) else { return nil }
        return previousItems[idx].id
    }

    open func oldIndexForItem(with id: UUID) -> Int? {
        previousItems.firstIndex { $0.id == id }
    }
}

extension ChatMessageListCollectionViewLayout {
    public struct LayoutItem {
        let id = UUID()
        public var offset: CGFloat
        public var height: CGFloat

        public var label: String = ""
        public var layoutOptions: ChatMessageLayoutOptions?
        public var previousLayoutOptions: ChatMessageLayoutOptions?

        public var isInitial = true

        public var maxY: CGFloat {
            offset + height
        }

        public init(offset: CGFloat, height: CGFloat) {
            self.offset = offset
            self.height = height
        }

        public func attribute(for index: Int, width: CGFloat) -> MessageCellLayoutAttributes {
            let attribute = MessageCellLayoutAttributes(forCellWith: IndexPath(item: index, section: 0))
            attribute.frame = CGRect(x: 0, y: offset, width: width, height: height)
            // default `zIndex` value is 0, but for some undocumented reason self-sizing
            // (concretely `contentView.systemLayoutFitting(...)`) doesn't work correctly,
            // so we need to make sure we do not use it, we need to add 1 so indexPath 0-0 doesn't have
            // problematic 0 zIndex
            attribute.zIndex = index + 1

            attribute.layoutOptions = layoutOptions
            attribute.previousLayoutOptions = previousLayoutOptions
            attribute.label = label
            attribute.isInitialAttributes = isInitial

            return attribute
        }
    }
}

extension ChatMessageListCollectionViewLayout {
    func recalculateLayout(items: inout [LayoutItem], visibleHeight: CGFloat) {
        print("👉 Recalculating layout: Bottom -> Top: \(visibleHeight)")

        // Completely recreate the layout such that it fits the last screen completely
        var offset = visibleHeight

        for i in 0..<items.count {
            var item = items[i]
            item.offset = offset - item.height
            offset -= (item.height + spacing)
            items[i] = item
        }

        // If the current items don't fit to the preferred height, recalculate again with top -> bottom approach
        let topOverflow = items.last?.offset ?? 0
        if topOverflow < 0 {
            print("  * Recalculating layout: Top -> Bottom: \(visibleHeight)")
            var offset: CGFloat = 0
            for i in (0..<items.count).reversed() {
                var item = items[i]
                item.offset = offset
                items[i] = item
                offset += spacing + item.height
            }
        }
    }

    func updateFinalContentSize() {
        previousContentSize = CGSize(
            width: collectionView!.bounds.width,
            height: max(collectionViewVisibleSize.height, currentItems.first!.maxY)
        )
    }

    func getRestoreOffset() -> CGFloat {
        collectionViewContentSize.height
            - collectionView!.contentOffset.y
            - collectionViewVisibleSize.height
    }

    func resolveRestoreOffset(_ restoreOffset: CGFloat) -> CGFloat {
        collectionViewContentSize.height
            - restoreOffset
            - collectionViewVisibleSize.height
    }
}

private extension UIScrollView {
    /// Return `true` if the scroll views is scrolling.
    var isScrolling: Bool {
        isDragging || isDecelerating
    }
}
