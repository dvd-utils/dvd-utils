#include <QtTest/QtTest>
#include "Subtitles/paletteinfo.h"

class TestPaletteInfo : public QObject
{
    Q_OBJECT

private slots:
    void defaultsToInvalidValues();
    void copiesOffsetAndSize();
    void settersUpdateValues();
};

void TestPaletteInfo::defaultsToInvalidValues()
{
    PaletteInfo info;

    QCOMPARE(info.paletteOffset(), -1);
    QCOMPARE(info.paletteSize(), -1);
}

void TestPaletteInfo::copiesOffsetAndSize()
{
    PaletteInfo original;
    original.setPaletteOffset(7);
    original.setPaletteSize(11);

    PaletteInfo copy(&original);

    QCOMPARE(copy.paletteOffset(), 7);
    QCOMPARE(copy.paletteSize(), 11);
}

void TestPaletteInfo::settersUpdateValues()
{
    PaletteInfo info;
    info.setPaletteOffset(42);
    info.setPaletteSize(99);

    QCOMPARE(info.paletteOffset(), 42);
    QCOMPARE(info.paletteSize(), 99);
}

QTEST_APPLESS_MAIN(TestPaletteInfo)
#include "test_paletteinfo.moc"
