// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#include "tray.h"

#include <KStatusNotifierItem>
#include <QIcon>
#include <QMenu>

Tray::Tray(QObject *parent)
    : QObject(parent)
    , m_item(new KStatusNotifierItem(QStringLiteral("hafen"), this))
{
    m_item->setTitle(QStringLiteral("Hafen"));
    m_item->setCategory(KStatusNotifierItem::ApplicationStatus);
    m_item->setStatus(KStatusNotifierItem::Active);
    m_item->setIconByPixmap(QIcon(QStringLiteral(":/qt/qml/Hafen/data/hafen.svg")));
    m_item->setToolTipTitle(QStringLiteral("Hafen"));
}

QWindow *Tray::window() const
{
    return m_window;
}

void Tray::setWindow(QWindow *window)
{
    if (m_window == window) {
        return;
    }
    m_window = window;
    // With an associated window a left click on the tray icon shows or hides it.
    m_item->setAssociatedWindow(window);
    Q_EMIT windowChanged();
}

QString Tray::subtitle() const
{
    return m_subtitle;
}

void Tray::setSubtitle(const QString &subtitle)
{
    if (m_subtitle == subtitle) {
        return;
    }
    m_subtitle = subtitle;
    m_item->setToolTipSubTitle(subtitle);
    Q_EMIT subtitleChanged();
}

bool Tray::warning() const
{
    return m_warning;
}

void Tray::setWarning(bool warning)
{
    if (m_warning == warning) {
        return;
    }
    m_warning = warning;
    m_item->setOverlayIconByName(warning ? QStringLiteral("dialog-warning") : QString());
    Q_EMIT warningChanged();
}

void Tray::notify(const QString &title, const QString &body, const QString &iconName)
{
    m_item->showMessage(title, body, iconName);
    Q_EMIT notified(title, body, iconName);
}

void Tray::setProjects(const QVariantList &projects)
{
    if (projects == m_projects) {
        return;
    }
    m_projects = projects;

    QMenu *menu = m_item->contextMenu();
    for (QAction *action : std::as_const(m_projectActions)) {
        menu->removeAction(action);
        // A submenu owns its menuAction(); deleting the menu deletes the action with it.
        if (QMenu *sub = action->menu()) {
            delete sub;
        } else {
            delete action;
        }
    }
    m_projectActions.clear();
    if (projects.isEmpty()) {
        return;
    }

    QAction *before = menu->actions().isEmpty() ? nullptr : menu->actions().constFirst();
    for (const QVariant &entry : projects) {
        const QVariantMap project = entry.toMap();
        const QString name = project.value(QStringLiteral("project")).toString();
        auto *sub = new QMenu(project.value(QStringLiteral("label")).toString());
        sub->setIcon(QIcon::fromTheme(project.value(QStringLiteral("active")).toBool() ? QStringLiteral("media-playback-start")
                                                                                         : QStringLiteral("media-playback-stop")));
        auto add = [this, sub, name](const QString &text, const QString &icon, const QString &action) {
            connect(sub->addAction(QIcon::fromTheme(icon), text), &QAction::triggered, this, [this, name, action] {
                Q_EMIT projectAction(name, action);
            });
        };
        if (project.value(QStringLiteral("canStart")).toBool()) {
            add(tr("Start"), QStringLiteral("media-playback-start"), QStringLiteral("start"));
        }
        if (project.value(QStringLiteral("canStop")).toBool()) {
            add(tr("Restart"), QStringLiteral("view-refresh"), QStringLiteral("restart"));
            add(tr("Stop…"), QStringLiteral("media-playback-stop"), QStringLiteral("stop"));
        }
        QAction *action = sub->menuAction();
        menu->insertAction(before, action);
        m_projectActions.append(action);
    }
    QAction *separator = new QAction(menu);
    separator->setSeparator(true);
    menu->insertAction(before, separator);
    m_projectActions.append(separator);
}
