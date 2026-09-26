import SwiftUI

/// Static ink rating like `★ 4.9` — Airbnb never colours the star.
struct RatingLabel: View {
    let rating: Double
    var trips: Int? = nil

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(TwendeColor.ink)
            Text(Format.stars(rating))
                .font(TwendeFont.captionMedium)
                .foregroundStyle(TwendeColor.ink)
            if let trips {
                Text("· \(L(.tripsCount, Format.grouped(trips)))")
                    .font(TwendeFont.caption)
                    .foregroundStyle(TwendeColor.inkSecondary)
            }
        }
    }
}

/// Five large tappable stars: filled stars are the soft 3D render, empty ones a hairline outline.
struct StarPicker: View {
    @Binding var rating: Int

    var body: some View {
        HStack(spacing: 12) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    Haptics.selection()
                    withAnimation(.spring(duration: 0.3, bounce: 0.4)) { rating = star }
                } label: {
                    Group {
                        if star <= rating {
                            Image("star_rating_butter")
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(width: 46, height: 46)
                        } else {
                            Image(systemName: "star")
                                .font(.system(size: 34, weight: .light))
                                .foregroundStyle(TwendeColor.border)
                        }
                    }
                    .scaleEffect(star == rating ? 1.12 : 1)
                        .frame(width: 52, height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(star)"))
            }
        }
    }
}
