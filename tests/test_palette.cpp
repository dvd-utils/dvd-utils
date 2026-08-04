#include <QtTest/QtTest>
#include "Subtitles/palette.h"
#include "Tools/hr_time.h"

class TestPalette : public QObject
{
    Q_OBJECT

private slots:
    void constructionDefaults();
    void setRgbUpdatesYcbcr();
    void setArgbPreservesAlpha();
    void transparentIndexFindsLowestAlpha();
    void yCbCrRoundTripBt601();
    void stopwatchReturnsNonNegativeElapsedTime();
};

void TestPalette::constructionDefaults()
{
    Palette palette(4, true);
    QCOMPARE(palette.size(), 4);
    for (int i = 0; i < palette.size(); ++i)
    {
        QCOMPARE(palette.alpha(i), 0);
        QCOMPARE(palette.rgb(i), qRgba(0, 0, 0, 0));
    }
}

void TestPalette::setRgbUpdatesYcbcr()
{
    Palette palette(2, true);
    palette.setRGB(1, qRgb(255, 128, 0));
    QCOMPARE(palette.rgb(1), qRgba(255, 128, 0, 0));
    QVector<int> yCbCr = palette.YCbCr(1);
    QVERIFY(yCbCr.size() == 3);
    QVERIFY(yCbCr[0] >= 16 && yCbCr[0] <= 235);
    QVERIFY(yCbCr[1] >= 16 && yCbCr[1] <= 240);
    QVERIFY(yCbCr[2] >= 16 && yCbCr[2] <= 240);
}

void TestPalette::setArgbPreservesAlpha()
{
    Palette palette(2, true);
    palette.setARGB(0, qRgba(10, 20, 30, 123));
    QCOMPARE(palette.rgba(0), qRgba(10, 20, 30, 123));
    QCOMPARE(palette.alpha(0), 123);
}

void TestPalette::transparentIndexFindsLowestAlpha()
{
    Palette palette(3, true);
    palette.setARGB(0, qRgba(1, 2, 3, 100));
    palette.setARGB(1, qRgba(4, 5, 6, 50));
    palette.setARGB(2, qRgba(7, 8, 9, 150));
    QCOMPARE(palette.transparentIndex(), 1);
}

void TestPalette::yCbCrRoundTripBt601()
{
    QRgb original = qRgb(100, 150, 200);
    QVector<int> yCbCr = Palette::RGB2YCbCr(original, true);
    QCOMPARE(yCbCr.size(), 3);
    Palette palette(1, true);
    palette.setYCbCr(0, yCbCr[0], yCbCr[1], yCbCr[2]);
    QRgb rgb = palette.rgb(0);
    QVERIFY(qRed(rgb) >= 0 && qRed(rgb) <= 255);
    QVERIFY(qGreen(rgb) >= 0 && qGreen(rgb) <= 255);
    QVERIFY(qBlue(rgb) >= 0 && qBlue(rgb) <= 255);
}

void TestPalette::stopwatchReturnsNonNegativeElapsedTime()
{
    CStopWatch watch;
    watch.startTimer();
    QTest::qWait(10);
    watch.stopTimer();

    const double elapsed = watch.getElapsedTime();
    QVERIFY(elapsed >= 0.0);
    QVERIFY(elapsed < 5.0);
}

QTEST_APPLESS_MAIN(TestPalette)
#include "test_palette.moc"
