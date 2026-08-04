#include <QtTest/QtTest>
#include "Tools/hr_time.h"

class TestHrTime : public QObject
{
    Q_OBJECT

private slots:
    void stopwatchReturnsNonNegativeElapsedTime();
};

void TestHrTime::stopwatchReturnsNonNegativeElapsedTime()
{
    CStopWatch watch;
    watch.startTimer();
    QTest::qWait(10);
    watch.stopTimer();

    const double elapsed = watch.getElapsedTime();
    QVERIFY(elapsed >= 0.0);
    QVERIFY(elapsed < 5.0);
}

QTEST_APPLESS_MAIN(TestHrTime)
#include "test_hr_time.moc"
