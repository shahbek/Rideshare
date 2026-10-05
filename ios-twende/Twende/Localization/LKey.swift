import Foundation

/// Every user-facing string. Both language tables must be exhaustive over this enum.
/// Keys whose copy contains placeholders are formatted with `String(format:)`; a literal percent sign in those must be `%%`.
nonisolated enum LKey: Hashable, Sendable {
    // Offline maps
    case offlineMaps, offlineMapsBody, offlineWiFiOnly, offlineDownloadedOnly, offlineOnlyBody
    case offlineSlipway, offlineSlipwayDetail, offlinePeninsula, offlinePeninsulaDetail, offlineCentral, offlineCentralDetail
    case offlineDownload, offlineUpdate, offlineReady, offlinePreparing, offlineDownloading, offlinePaused, offlineResume
    case offlineFailed, offlineRemoveFailed, offlineRemoveTitle, offlineRemoveBody, offlineInventoryFailed
    case offlineDisableOnly, offlineConnect, offlineNeedWiFi, offlineLimitations, offlineBundled, offlinePartial, offlineProgress

    // Common
    case back, close, cancel, continueAction, skip, change, remove, delete, clear, gotIt, verify
    case copy, copied, seeAll, saved, saveChanges, menu, recentre, request, notNow, tryAgain, backToHome
    case minutesShort, minuteUnit, darEsSalaam, madeInDar, nearPlace, droppedPin, yourLocation, recommended

    // Splash & language
    case splashTagline, splashFooter, languageTitle, languageSubtitle

    // Phone & OTP
    case phoneTitle, phoneSubtitle, phoneLabel, phoneHint, sendCode
    case otpTitle, otpSubtitle, otpResendIn, otpResend, otpChangeNumber, otpInvalid, otpDemoHint

    // Profile setup
    case profileTitle, profileSubtitle, fullName, fullNamePlaceholder, emailOptional, profilePrivacy

    // Permission primers
    case locationTitle, locationSubtitle, locationBullet1, locationBullet2, locationBullet3, allowLocation, locationDeniedHint
    case notificationsTitle, notificationsSubtitle, notificationsBullet1, notificationsBullet2, notificationsBullet3, allowNotifications

    // Native tabs
    case tabHome, tabActivity

    // Home
    case goodMorning, goodAfternoon, goodEvening, whereTo, searchDestinationHint, favouritesOnline, demoLocation
    case addHome, addWork, myDrivers, noFavouritesTitle, noFavouritesBody, recent, noRecents, offlineBanner
    case serviceRide, serviceBajaji, serviceBoda, letsGo, driversNearbyCount

    // Search
    case pickupLabel, popularPlaces, setOnMap, searchingPlaces, noResultsTitle, noResultsBody, requestingDriver, chooseDestinationFirst
    case stopLabel, addStop, addAnotherStop, stopsCount, removeStop, whereToNext, setStopTitle, confirmStopHere, chooseDestination, maxStopsReached, viaStops, viaOneStop

    case reorderRoute, reorderRouteHint, moveEarlier, moveLater

    // Set on map & confirm pickup
    case setPickupTitle, setDestinationTitle, confirmPickupHere, confirmDestinationHere, outOfZoneShort
    case confirmPickupTitle, pickupNotePlaceholder, confirmPickup

    // Ride options
    case chooseRide, fareDetails, pickupInMinutes, fewDriversNearby, promoCode, willAskDriverFirst
    case pickupInOneMinute, dropoffAtTime, pickupUnavailable, dropoffUnavailable
    case expandRideOptions, collapseRideOptions
    case requestDriver, requestRide, requestTier
    case tierEconomy, tierComfort, tierPremium, tierBajaji, tierBoda
    case tierEconomyDescription, tierComfortDescription, tierPremiumDescription, tierBajajiDescription, tierBodaDescription

    // Zero commission
    case badgeDriverReceives100, badgeDriverReceivesAmount, badgeDriverReceived
    case zeroCommissionTitle, zeroCommissionBody
    case zeroCommissionPoint1Title, zeroCommissionPoint1Body
    case zeroCommissionPoint2Title, zeroCommissionPoint2Body
    case zeroCommissionPoint3Title, zeroCommissionPoint3Body
    case exampleFare

    // Fare breakdown
    case fareBreakdownTitle, baseFare, distanceFare, timeFare, promoDiscount, tip, total, fareBreakdownNote

    // Payment
    case payWith, cashDetail, addMobileMoney, payment, payments, defaultMethod, unlink, paymentsNote
    case linkWallet, useAccountPhone, walletNumber, linkWalletNote, linkAction

    // Twende wallet
    case wallet, walletBalance, walletBalanceDetail, walletEmptyDetail, walletInsufficient, topUp, topUpWallet
    case topUpAmount, topUpCustomAmount, topUpFrom, topUpNoRails, topUpLinkRail, topUpConfirm, topUpDone
    case topUpMinimum, topUpMaximum, walletHistory, walletNoHistory, walletTopUpTitle, walletRidePayment
    case walletRefund, walletExplainer, walletPaid, walletShortBody, walletShortTopUp, payWithWallet, walletAfterRide

    // Promo codes
    case enterCode, applyCode, promoHint, promoInvalid
    case promoKaribuTitle, promoKaribuDetail, promoTwende10Title, promoTwende10Detail

    // Out of zone
    case outOfZoneTitle, outOfZoneBody, notifyMeZone, notifyMeZoneConfirmed, notifyMeZoneAlready, chooseAnotherPlace

    // Quick request
    case awayFromYou, pickupEta, viewProfile

    // Searching / no drivers
    case askingDriver, findingDriver, usuallyUnder, cancelRequest
    case noDriversTitle, noDriversBody, tryAnotherRide, notifyWhenDrivers

    // Driver en route / arrived
    case driverOnTheWay, driverArrivedTitle, meetAtPickup, arrivingIn, hereNow
    case call, message, favourite, addFavourite, cancelRide, plateNumber, shareTrip, sos, shareTripMessage
    case ridePINTitle, ridePINBody, ridePINArrivedBody, ridePINAccessibility

    // In trip
    case headingTo, inTraffic, movingWell, trafficMinutes, remaining, fareLabel
    case changeDestination, changeDestinationNote, destinationChanged

    // Cancellation
    case cancelReasonTitle, cancelReasonBody
    case cancelWaitTooLong, cancelDriverNotMoving, cancelWrongPickup, cancelChangedPlans, cancelDriverAsked, cancelOther
    case cancellationFeeNotice, driverAskedNotice, cancelWithFee, confirmCancel, keepRide
    case cancelledWithFee, cancelledNoFee, cancelledLabel, cancellationReason, cancellationFee

    // SOS
    case sosTitle, sosBody, sosCallPolice, sosConfirmCall, sosCallNow, sosAlertContacts, sosContactsAlerted, addEmergencyContacts

    // Completion & payment
    case tripCompleteTitle, addTip, noTip, tipNote, payDriverInCash, tapToPay
    case paymentPendingBody, paymentConfirmed, paymentFailed, paymentFailedBody
    case confirmCashPaid, retryPayment, payWithMethod, payCashInstead, waitingForConfirmation

    // Rating
    case rateDriver, rateTrip, whatWentWrong
    case ratingReasonRoute, ratingReasonDriving, ratingReasonVehicle, ratingReasonBehaviour, ratingReasonLate, ratingReasonPrice
    case addToMyDrivers, addToMyDriversShort, submitRating, thanksForRating

    // History & receipt
    case tripHistory, tripHistorySubtitle, noTripsTitle, noTripsBody, receipt, dropoffLabel
    case latraNotice, shareReceipt, prepareReceipt, rebook, reportIssue

    // Menu
    case profile, myDriversSubtitle, onlineCount, savedPlaces, savedPlacesSubtitle
    case promotions, promotionsSubtitle, safetyCentre, safetySubtitle, support, supportSubtitle, settings, tripsTaken

    // Profile
    case phoneLockedHint, memberSince

    // My drivers
    case myDriversExplainer, noFavouritesLong, addByPhone, addByPhoneBody, addByPhoneHint, addDriver
    case driverAdded, driverNotFound, notifyWhenOnline, statusOnline, statusBusy, statusOffline, driverNowOnline

    // Driver detail
    case memberSinceShort, rideType, seats, notifyWhenOnlineBody, tripsWithDriver, driverUnavailable, removeFromMyDrivers, tripsCount

    // Saved places
    case tapToSet, addPlace, editPlace, placeType, homeLabel, workLabel, otherLabel
    case placeLabel, placeLabelPlaceholder, location, searchPlace, savePlace, deletePlace

    // Promotions
    case referralTitle, referralBody, referralMessage, shareWhatsApp, shareOther, yourCodes, used, expiresOn, promoTerms

    // Safety
    case sosDuringTrip, sosDuringTripBody, emergencyContacts, addContact, maxContacts, contactNamePlaceholder, saveContact
    case autoShareTrips, autoShareTripsBody, safetyTips, safetyTip1, safetyTip2, safetyTip3, safetyTip4

    // Support
    case chatWhatsApp, callSupport, supportHours, lastTrip, faq
    case faqQ1, faqA1, faqQ2, faqA2, faqQ3, faqA3, faqQ4, faqA4, faqQ5, faqA5, faqQ6, faqA6
    case legal, termsOfService, privacyPolicy

    // Settings
    case language, notifications, tripUpdates, promoUpdates, account, logOut, logOutConfirmTitle
    case mapStyle, mapStyleBody
    case mapStyleMonochromeDay, mapStyleMonochromeDayBody
    case mapStyleMonochromeDusk, mapStyleMonochromeDuskBody
    case mapStyleNight, mapStyleNightBody
    case mapStyleDawn, mapStyleDawnBody
    case mapStyleColourDay, mapStyleColourDayBody
    case mapStyleFaded, mapStyleFadedBody
    case deleteAccount, deleteAccountSubtitle, deleteAccountConfirmTitle, deleteAccountConfirmBody, deleteAccountConfirm

    // Siri, Shortcuts & widget guide
    case siriGuide, siriGuideSubtitle, siriGuideIntro
    case siriGuideBookTitle, siriGuideBookBody, siriGuideBookPhrase1, siriGuideBookPhrase2, siriGuideBookPhrase3
    case siriGuideRideTitle, siriGuideRideBody, siriGuideRidePhrase1, siriGuideRidePhrase2, siriGuideRidePhrase3
    case siriGuideScreenTitle, siriGuideScreenBody
    case siriGuideScreen1, siriGuideScreen1Body, siriGuideScreen2, siriGuideScreen2Body, siriGuideScreen3, siriGuideScreen3Body
    case siriGuideScreen4, siriGuideScreen4Body, siriGuideScreen5, siriGuideScreen5Body
    case siriGuideShortcutsTitle, siriGuideShortcutsBody, siriGuideOpenShortcuts
    case siriGuideWidgetTitle, siriGuideWidgetBody, siriGuideWidgetStep1, siriGuideWidgetStep2, siriGuideWidgetStep3
    case siriGuideAvailability, siriGuideTryIt

    // Mobile money, ID verification, billboards
    case topUpChooseWallet, topUpEnterAmount, topUpAddFrom, topUpNewBalance, topUpMinimumHint, notLinked, linkShort, linked, linkWithNumber, useAnotherNumber, autoTopUp, autoTopUpOff, autoTopUpSummary, autoTopUpTitle, autoTopUpBody, autoTopUpThreshold, autoTopUpAmount, autoTopUpFrom, autoTopUpSave, autoTopUpNeedsWallet, autoTopUpInvalid, autoTopUpDone, walletAutoTopUpTitle, mmWaitingRow, mmCheckPhoneTitle, mmCheckPhoneBody, mmRidePromptBody, mmExpiresIn, mmKeepOpen, mmTestMode, mmTestModeBody, mmPromptText, mmPromptPin, mmPromptSend, mmPromptCancel, mmPromptHint, mmSimulateInsufficient, mmApprovedTitle, mmApprovedBody, mmReference, mmDone, mmChangeAmount, mmFailDeclined, mmFailDeclinedBody, mmFailWrongPin, mmFailWrongPinBody, mmFailTimeout, mmFailTimeoutBody, mmFailFunds, mmFailFundsBody, mmFailOther, mmFailOtherBody, mmStartFailed, idVerify, idVerified, idVerifySubtitle, idPrimerTitle, idPrimerSubtitle, idPrimerBullet1, idPrimerBullet2, idPrimerBullet3, idScanAction, idSkip, idScanTitle, idScanHintPassport, idScanHintAlign, idScanHintSteady, idScanHintCloser, idScanHintGlare, idScanHintReading, idScanCaptured, idCameraDeniedTitle, idCameraDeniedBody, idNoCameraTitle, idNoCameraBody, idOpenSettings, idReviewTitle, idReviewSubtitle, idChecksumOK, idGivenNames, idSurname, idDocumentNumber, idNationality, idSex, idSexFemale, idSexMale, idSexUnspecified, idDateOfBirth, idExpiry, idCheckField, idUseCardPhoto, idUseName, idConfirm, idRescan, idMissingError, idUnderageError, idExpiredError, idSaved, idKindNida, idKindPassport, idKindNationalID, idKindDriving, idKindResidence, idKindOther, idDocumentType, idStatusBody, idRemove, adSponsored, adTestBadge, adKfcHeadline, adKfcOffer, adNearestBranch, adRideThere, adDisclaimer

    // Wallet steps, number changes, Google sign-in
    case changeWalletNumber, topUpStep1, topUpStep2, topUpStep3, changeNumberTitle, currentNumber, unlinkWallet
    case signInTitle, signInSubtitle, signInGoogle, signInPhoneInstead, signInTerms, signInFailed, signedInAs, signOutGoogle, accountSynced

    // Wallet ownership (SMS code)
    case walletEnterCode, walletCodeSentTo, walletTestCode, walletDetectedAs, walletDetectedName, walletWrongNetwork, walletSwitchTo, walletUnknownNetwork, walletSendCode, walletResendCode, walletResendIn, walletEditNumber, walletVerifiedToast, walletNeedsVerify, walletOwnershipNote

    // Route editing, address lookup, ride chat
    case yourRideNow, routeUpdated, changingThisStop, tapToChange, changeRoute, planYourTrip, searchPickup, newFare, updateRoute, findingAddress, chatWithDriver, chatAutoTranslate, chatEmpty, chatQuickComing, chatQuickHere, chatQuickFiveMin, chatQuickWhere, chatPlaceholder, chatSend, chatTranslated
}
