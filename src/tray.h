// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#pragma once

#include <QObject>
#include <QList>
#include <QPointer>
#include <QVariantList>
#include <QWindow>
#include <QtQml/qqmlregistration.h>

class KStatusNotifierItem;
class QAction;

class Tray : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    Q_PROPERTY(QWindow *window READ window WRITE setWindow NOTIFY windowChanged)
    Q_PROPERTY(QString subtitle READ subtitle WRITE setSubtitle NOTIFY subtitleChanged)
    Q_PROPERTY(bool warning READ warning WRITE setWarning NOTIFY warningChanged)

public:
    explicit Tray(QObject *parent = nullptr);

    QWindow *window() const;
    void setWindow(QWindow *window);
    QString subtitle() const;
    void setSubtitle(const QString &subtitle);
    bool warning() const;
    void setWarning(bool warning);

    Q_INVOKABLE void notify(const QString &title, const QString &body, const QString &iconName);

    // Compose projects for the tray's context menu: [{ project, label, active, canStart, canStop }].
    // Each becomes a submenu above KStatusNotifierItem's own entries; a click emits projectAction.
    Q_INVOKABLE void setProjects(const QVariantList &projects);

Q_SIGNALS:
    void projectAction(const QString &project, const QString &action);
    void windowChanged();
    void subtitleChanged();
    void warningChanged();

private:
    KStatusNotifierItem *m_item;
    QPointer<QWindow> m_window;
    QString m_subtitle;
    bool m_warning = false;
    QVariantList m_projects;
    QList<QAction *> m_projectActions;
};
