#include <QtTest/QtTest>
#include "Tools/numberutil.h"

class TestNumberUtil : public QObject
{
    Q_OBJECT

private slots:
    void setByteStoresLowByte();
    void setWordStoresBigEndianWord();
    void setDWordStoresBigEndianDWord();
    void setStringWritesAsciiCharacters();
};

void TestNumberUtil::setByteStoresLowByte()
{
    QList<uchar> buffer = {0, 0, 0};
    NumberUtil::setByte(buffer, 1, 0x7f);

    QCOMPARE(buffer[0], uchar(0));
    QCOMPARE(buffer[1], uchar(0x7f));
    QCOMPARE(buffer[2], uchar(0));
}

void TestNumberUtil::setWordStoresBigEndianWord()
{
    QList<uchar> buffer = {0, 0, 0, 0};
    NumberUtil::setWord(buffer, 1, 0x1234);

    QCOMPARE(buffer[0], uchar(0));
    QCOMPARE(buffer[1], uchar(0x12));
    QCOMPARE(buffer[2], uchar(0x34));
    QCOMPARE(buffer[3], uchar(0));
}

void TestNumberUtil::setDWordStoresBigEndianDWord()
{
    QList<uchar> buffer = {0, 0, 0, 0, 0};
    NumberUtil::setDWord(buffer, 1, 0x12345678);

    QCOMPARE(buffer[0], uchar(0));
    QCOMPARE(buffer[1], uchar(0x12));
    QCOMPARE(buffer[2], uchar(0x34));
    QCOMPARE(buffer[3], uchar(0x56));
    QCOMPARE(buffer[4], uchar(0x78));
}

void TestNumberUtil::setStringWritesAsciiCharacters()
{
    QList<uchar> buffer = {0, 0, 0, 0};
    NumberUtil::setString(buffer, 1, QString("AB"));

    QCOMPARE(buffer[0], uchar(0));
    QCOMPARE(buffer[1], uchar('A'));
    QCOMPARE(buffer[2], uchar('B'));
    QCOMPARE(buffer[3], uchar(0));
}

QTEST_APPLESS_MAIN(TestNumberUtil)
#include "test_numberutil.moc"
