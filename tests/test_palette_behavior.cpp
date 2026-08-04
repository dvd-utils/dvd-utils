#include <QtTest/QtTest>
#include "Subtitles/palette.h"

class TestPaletteBehavior : public QObject
{
    Q_OBJECT

private slots:
    void copyConstructorPreservesPaletteState();
    void explicitConstructorInitializesColors();
    void setColorUpdatesRgbAndAlpha();
    void setYcbcrPreservesAlpha();
    void transparentIndexPrefersFirstEntryForEqualMinimumAlpha();
};

void TestPaletteBehavior::copyConstructorPreservesPaletteState()
{
    Palette original(2, true);
    original.setARGB(0, qRgba(10, 20, 30, 40));
    original.setARGB(1, qRgba(100, 110, 120, 200));

    Palette copy(&original);

    QCOMPARE(copy.size(), 2);
    QCOMPARE(copy.rgba(0), original.rgba(0));
    QCOMPARE(copy.rgba(1), original.rgba(1));
    QCOMPARE(copy.alpha(0), 40);
    QCOMPARE(copy.alpha(1), 200);
    QCOMPARE(copy.YCbCr(0), original.YCbCr(0));
    QCOMPARE(copy.YCbCr(1), original.YCbCr(1));
}

void TestPaletteBehavior::explicitConstructorInitializesColors()
{
    QList<uchar> red = {1, 2};
    QList<uchar> green = {3, 4};
    QList<uchar> blue = {5, 6};
    QList<uchar> alpha = {7, 8};

    Palette palette(red, green, blue, alpha, false);

    QCOMPARE(palette.size(), 2);
    QCOMPARE(palette.rgba(0), qRgba(1, 3, 5, 7));
    QCOMPARE(palette.rgba(1), qRgba(2, 4, 6, 8));
    QCOMPARE(palette.alpha(0), 7);
    QCOMPARE(palette.alpha(1), 8);
    QCOMPARE(palette.color(0).rgba(), qRgba(1, 3, 5, 7));
}

void TestPaletteBehavior::setColorUpdatesRgbAndAlpha()
{
    Palette palette(1, true);
    palette.setColor(0, QColor(42, 96, 180, 77));

    QCOMPARE(palette.rgba(0), qRgba(42, 96, 180, 77));
    QCOMPARE(palette.color(0).red(), 42);
    QCOMPARE(palette.color(0).green(), 96);
    QCOMPARE(palette.color(0).blue(), 180);
    QCOMPARE(palette.color(0).alpha(), 77);
}

void TestPaletteBehavior::setYcbcrPreservesAlpha()
{
    Palette palette(1, true);
    palette.setARGB(0, qRgba(10, 20, 30, 99));
    palette.setYCbCr(0, 16, 128, 128);

    QCOMPARE(palette.alpha(0), 99);
    QCOMPARE(palette.YCbCr(0).at(0), 16);
    QCOMPARE(palette.YCbCr(0).at(1), 128);
    QCOMPARE(palette.YCbCr(0).at(2), 128);
}

void TestPaletteBehavior::transparentIndexPrefersFirstEntryForEqualMinimumAlpha()
{
    Palette palette(3, true);
    palette.setARGB(0, qRgba(1, 2, 3, 100));
    palette.setARGB(1, qRgba(4, 5, 6, 100));
    palette.setARGB(2, qRgba(7, 8, 9, 150));

    QCOMPARE(palette.transparentIndex(), 0);
}

QTEST_APPLESS_MAIN(TestPaletteBehavior)
#include "test_palette_behavior.moc"
