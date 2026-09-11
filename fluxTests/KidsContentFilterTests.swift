import Testing
import Foundation
@testable import flux

@MainActor
struct KidsContentFilterTests {

    @Test func whitelistedCertificationsPass() {
        let filter = KidsContentFilter(diskStorage: false)

        let safeRatings = [
            "G", "PG",
            "TV-Y", "TVY",
            "TV-Y7", "TVY7", "TV-Y7-FV",
            "TV-G", "TVG",
            "TV-PG", "TVPG",
            "U",
            "0", "6", "FSK 0", "FSK 6",
            "Approved", "Passed", "General", "E"
        ]

        for rating in safeRatings {
            #expect(filter.isCertificationSafe(rating) == true, "Expected \(rating) to be allowed for kids")
        }
    }

    @Test func blockedCertificationsFail() {
        let filter = KidsContentFilter(diskStorage: false)

        let restrictedRatings = [
            "PG-13", "PG13",
            "R", "NC-17", "NC17",
            "TV-14", "TV14",
            "TV-MA", "TVMA",
            "12", "12A", "15", "18", "16",
            "M", "MA15+", "R18+",
            "X", "XXX", "A",
            "NR", "Not Rated", "Unrated", "UR",
            nil, ""
        ]

        for rating in restrictedRatings {
            #expect(filter.isCertificationSafe(rating) == false, "Expected \(String(describing: rating)) to be blocked for kids")
        }
    }

    @Test func mediaItemWithAllowedCertificationIsSafe() async {
        let filter = KidsContentFilter(diskStorage: false)
        let item = MediaItem(
            id: "kids-test-1",
            title: "Finding Nemo",
            description: "A clownfish swims across the ocean",
            streamURL: nil,
            category: "Movie",
            certification: "G"
        )

        let isSafe = await filter.isKidsSafe(item: item)
        #expect(isSafe == true)
        #expect(filter.isRestricted(item: item) == false)
    }

    @Test func mediaItemWithRestrictedCertificationIsBlocked() async {
        let filter = KidsContentFilter(diskStorage: false)
        let item = MediaItem(
            id: "adult-test-1",
            title: "Deadpool",
            description: "Merc with a mouth",
            streamURL: nil,
            category: "Movie",
            certification: "R"
        )

        let isSafe = await filter.isKidsSafe(item: item)
        #expect(isSafe == false)
        #expect(filter.isRestricted(item: item) == true)
    }

    @Test func unratedItemWithFamilyGenresIsPermitted() async {
        let filter = KidsContentFilter(diskStorage: false)
        let item = MediaItem(
            id: "unrated-animation-1",
            title: "Cute Animal Shorts",
            description: "Short animated stories",
            streamURL: nil,
            category: "Movie",
            genres: ["Animation", "Family", "Comedy"]
        )

        let isSafe = await filter.isKidsSafe(item: item)
        #expect(isSafe == true)
    }

    @Test func unratedItemWithAdultGenresIsRestricted() async {
        let filter = KidsContentFilter(diskStorage: false)
        let item = MediaItem(
            id: "unrated-horror-1",
            title: "Creepy Woods",
            description: "Spooky happenings in the dark",
            streamURL: nil,
            category: "Movie",
            genres: ["Horror", "Thriller"]
        )

        let isSafe = await filter.isKidsSafe(item: item)
        #expect(isSafe == false)
        #expect(filter.isRestricted(item: item) == true)
    }

    @Test func filterSafeItemsConcurrentlyPreservesOrder() async {
        let filter = KidsContentFilter(diskStorage: false)

        let itemG = MediaItem(id: "item-g", title: "G Title", description: "", streamURL: nil, category: "Movie", certification: "G")
        let itemR = MediaItem(id: "item-r", title: "R Title", description: "", streamURL: nil, category: "Movie", certification: "R")
        let itemPG = MediaItem(id: "item-pg", title: "PG Title", description: "", streamURL: nil, category: "Movie", certification: "PG")
        let itemTVMA = MediaItem(id: "item-tvma", title: "TV-MA Title", description: "", streamURL: nil, category: "TV Show", certification: "TV-MA")
        let itemFamily = MediaItem(id: "item-family", title: "Family Title", description: "", streamURL: nil, category: "Movie", genres: ["Family", "Animation"])

        let mixed = [itemG, itemR, itemPG, itemTVMA, itemFamily]
        let filtered = await filter.filterSafeItems(mixed)

        #expect(filtered.count == 3)
        #expect(filtered[0].id == "item-g")
        #expect(filtered[1].id == "item-pg")
        #expect(filtered[2].id == "item-family")
    }

    @Test func inMemoryCachingCachesSafetyDecisions() async {
        let filter = KidsContentFilter(diskStorage: false)
        filter.resetCacheForTesting()

        let item = MediaItem(id: "cached-test-1", title: "Toy Story", description: "", streamURL: nil, category: "Movie", certification: "G")
        let firstCheck = await filter.isKidsSafe(item: item)
        #expect(firstCheck == true)

        // After initial check, should resolve instantly from cache
        #expect(filter.isRestricted(item: item) == false)
    }

    @Test func safeBrowseGenresForKids() {
        let filter = KidsContentFilter(diskStorage: false)

        #expect(filter.isGenreSafeForKids("Animation") == true)
        #expect(filter.isGenreSafeForKids("Adventure") == true)
        #expect(filter.isGenreSafeForKids("Comedy") == true)
        #expect(filter.isGenreSafeForKids("Family") == true)
        #expect(filter.isGenreSafeForKids("Fantasy") == true)
        #expect(filter.isGenreSafeForKids("Short Films") == true)

        #expect(filter.isGenreSafeForKids("Horror") == false)
        #expect(filter.isGenreSafeForKids("Crime") == false)
        #expect(filter.isGenreSafeForKids("Thriller") == false)
        #expect(filter.isGenreSafeForKids("War") == false)
        #expect(filter.isGenreSafeForKids("Mystery") == false)
        #expect(filter.isGenreSafeForKids("Romance") == false)
    }

    @Test func adultTitleBlacklistBlocksKnownRestrictedTitles() async {
        let filter = KidsContentFilter(diskStorage: false)

        let adultTitles = [
            "Pinocchio: Unstrung",
            "Toxic",
            "South Park",
            "Family Guy",
            "Rick and Morty",
            "Invincible",
            "Attack on Titan",
            "Demon Slayer: Kimetsu no Yaiba",
            "Deadpool",
            "Terrifier 3",
            "Saw X"
        ]

        for title in adultTitles {
            let item = MediaItem(
                id: "test-\(title)",
                title: title,
                description: "",
                streamURL: nil,
                category: "Movie",
                genres: ["Animation", "Comedy"] // Even if disguised as Animation/Comedy
            )
            let isSafe = await filter.isKidsSafe(item: item)
            #expect(isSafe == false, "Expected \(title) to be blocked for kids")
            #expect(filter.isRestricted(item: item) == true, "Expected \(title) to be synchronously restricted")
        }
    }

    @Test func adultDescriptionKeywordsBlockContent() async {
        let filter = KidsContentFilter(diskStorage: false)

        let item = MediaItem(
            id: "desc-test-1",
            title: "Unknown Animated Tale",
            description: "A foul-mouthed group embarks on a journey filled with bloodshed and psychological horror.",
            streamURL: nil,
            category: "Movie",
            genres: ["Animation"]
        )

        let isSafe = await filter.isKidsSafe(item: item)
        #expect(isSafe == false)
        #expect(filter.isRestricted(item: item) == true)
    }

    @Test func safeKidsTitlesPassInKeylessMode() async {
        let filter = KidsContentFilter(diskStorage: false)

        let safeTitles = [
            "Toy Story",
            "Finding Nemo",
            "Cars",
            "The Lion King",
            "Frozen",
            "Moana",
            "The Wild Robot",
            "Avatar: The Last Airbender",
            "Bluey"
        ]

        for title in safeTitles {
            let item = MediaItem(
                id: "safe-\(title)",
                title: title,
                description: "Wholesome family adventure",
                streamURL: nil,
                category: "Movie",
                genres: ["Animation", "Family"]
            )
            let isSafe = await filter.isKidsSafe(item: item)
            #expect(isSafe == true, "Expected \(title) to be allowed for kids")
            #expect(filter.isRestricted(item: item) == false, "Expected \(title) not to be restricted")
        }
    }
}
