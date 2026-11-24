// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#include "fixture.h"

#include <QDir>
#include <QFile>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlContext>
#include <QQmlEngine>
#include <QSettings>

Fixture::Fixture()
{
    if (!m_dir.isValid()) {
        qFatal("No temporary directory for the UI tests.");
    }
    qputenv("HAFEN_FAKE_DIR", m_dir.path().toUtf8());
    qputenv("PATH", QByteArray(HAFEN_TEST_BIN_DIR) + ':' + qgetenv("PATH"));
    // Settings, autostart file and everything else Hafen writes stay inside the temporary directory.
    qputenv("XDG_CONFIG_HOME", (m_dir.path() + QStringLiteral("/config")).toUtf8());
}

void Fixture::reset()
{
    for (const char *name : {"containers", "removed"}) {
        QDir(path(QString::fromLatin1(name))).removeRecursively();
    }
    for (const char *name : {"fail.json", "daemon-down", "contexts.json"}) {
        QFile::remove(path(QString::fromLatin1(name)));
    }
    // Truncated, not removed: the fake `docker events` of the last test may still follow the file.
    for (const char *name : {"calls.log", "launched.log", "events.log"}) {
        write(QString::fromLatin1(name), QByteArray());
    }

    QFile scenario(QStringLiteral(HAFEN_TEST_SCENARIO));
    if (!scenario.open(QIODevice::ReadOnly)) {
        qFatal("The scenario file is not readable.");
    }
    QDir().mkpath(path(QStringLiteral("containers")));
    const QJsonArray containers = QJsonDocument::fromJson(scenario.readAll()).array();
    if (containers.isEmpty()) {
        qFatal("The scenario file holds no containers.");
    }
    for (const auto &value : containers) {
        const QJsonObject container = value.toObject();
        write(QStringLiteral("containers/%1.json").arg(container.value(QStringLiteral("id")).toString()), QJsonDocument(container).toJson(QJsonDocument::Compact));
    }

    QSettings settings;
    settings.clear();
    settings.setValue(QStringLiteral("checkUpdates"), false);
    settings.setValue(QStringLiteral("terminal"), QStringLiteral("fake-terminal -e"));
    settings.sync();
}

QStringList Fixture::calls() const
{
    QStringList result;
    for (const QString &line : lines(QStringLiteral("calls.log"))) {
        QStringList words;
        for (const auto &word : QJsonDocument::fromJson(line.toUtf8()).array()) {
            words.append(word.toString());
        }
        result.append(words.join(QLatin1Char(' ')));
    }
    return result;
}

QVariantList Fixture::launched() const
{
    QVariantList result;
    for (const QString &line : lines(QStringLiteral("launched.log"))) {
        result.append(QVariant(QJsonDocument::fromJson(line.toUtf8()).array().toVariantList()));
    }
    return result;
}

void Fixture::patchContainer(const QString &id, const QVariantMap &changes)
{
    const QString name = QStringLiteral("containers/%1.json").arg(id);
    QFile file(path(name));
    if (!file.open(QIODevice::ReadOnly)) {
        qFatal("The scenario has no container %s.", qPrintable(id));
    }
    QJsonObject container = QJsonDocument::fromJson(file.readAll()).object();
    file.close();
    for (auto it = changes.cbegin(); it != changes.cend(); ++it) {
        container.insert(it.key(), QJsonValue::fromVariant(it.value()));
    }
    write(name, QJsonDocument(container).toJson(QJsonDocument::Compact));

    QFile events(path(QStringLiteral("events.log")));
    if (!events.open(QIODevice::Append)) {
        qFatal("events.log is not writable.");
    }
    events.write(QJsonDocument(QJsonObject{{QStringLiteral("Type"), QStringLiteral("container")}, {QStringLiteral("Action"), QStringLiteral("update")}, {QStringLiteral("id"), id}})
                     .toJson(QJsonDocument::Compact)
                 + '\n');
}

void Fixture::failCommand(const QString &words, const QString &stderrText)
{
    QFile file(path(QStringLiteral("fail.json")));
    QJsonObject fails;
    if (file.open(QIODevice::ReadOnly)) {
        fails = QJsonDocument::fromJson(file.readAll()).object();
        file.close();
    }
    fails.insert(words, stderrText);
    write(QStringLiteral("fail.json"), QJsonDocument(fails).toJson(QJsonDocument::Compact));
}

void Fixture::setDaemonDown(bool down)
{
    if (down) {
        write(QStringLiteral("daemon-down"), QByteArray());
    } else {
        QFile::remove(path(QStringLiteral("daemon-down")));
    }
}

void Fixture::setContexts(const QVariantList &contexts)
{
    write(QStringLiteral("contexts.json"), QJsonDocument(QJsonArray::fromVariantList(contexts)).toJson(QJsonDocument::Compact));
}

void Fixture::setSetting(const QString &key, const QVariant &value)
{
    QSettings settings;
    settings.setValue(key, value);
    settings.sync();
}

QString Fixture::path(const QString &name) const
{
    return m_dir.filePath(name);
}

QString Fixture::read(const QString &name) const
{
    QFile file(path(name));
    return file.open(QIODevice::ReadOnly) ? QString::fromUtf8(file.readAll()) : QString();
}

bool Fixture::exists(const QString &name) const
{
    return QFile::exists(path(name));
}

QString Fixture::artifact(const QString &name) const
{
    const QDir dir(QStringLiteral(HAFEN_TEST_ARTIFACT_DIR));
    if (!dir.mkpath(QStringLiteral("."))) {
        qFatal("%s could not be created.", HAFEN_TEST_ARTIFACT_DIR);
    }
    const QString language = qEnvironmentVariable("HAFEN_TEST_LANGUAGE");
    return dir.filePath(language.isEmpty() ? name : language + QLatin1Char('-') + name);
}

void Fixture::qmlEngineAvailable(QQmlEngine *engine)
{
    engine->rootContext()->setContextProperty(QStringLiteral("fixture"), this);
}

QStringList Fixture::lines(const QString &name) const
{
    QFile file(path(name));
    if (!file.open(QIODevice::ReadOnly)) {
        return {};
    }
    return QString::fromUtf8(file.readAll()).split(QLatin1Char('\n'), Qt::SkipEmptyParts);
}

void Fixture::write(const QString &name, const QByteArray &content) const
{
    QFile file(path(name));
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate) || file.write(content) != content.size()) {
        qFatal("%s is not writable.", qPrintable(file.fileName()));
    }
}
